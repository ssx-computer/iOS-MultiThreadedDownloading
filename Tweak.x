// SafariGoPeed - 捕获 Safari 的所有下载请求 → 自动跳转 GoPeed (iOS) 8线程下载
// 兼容 Dopamine / RootHide（越狱根目录 /var/jb 自适应）
// 注入进程：MobileSafari（主进程，负责拉起 GoPeed）+ com.apple.WebKit.WebContent（网络/下载进程）
//
// 关键设计（跨进程跳转）：
//   Safari 的网络与下载发生在 WebContent 进程，但 [UIApplication openURL:] 只有在
//   主 app 进程（MobileSafari）里才能拉起外部 app（GoPeed）。
//   → WebContent 捕获到下载后，通过 Darwin 通知广播给主进程 MobileSafari，
//     由主进程调用 openURL 拉起 GoPeed。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *gLogPath = nil;
static NSLock   *gLock = nil;

// 跳转到 GoPeed 使用的线程数（HTTP 连接数）
static const int GOPEED_THREADS = 8;
// 同一 URL 的去重窗口（秒）
static const double GOPEED_DEDUP_WINDOW = 10.0;
// Darwin 通知名（WebContent -> MobileSafari 广播下载事件）
static NSString *const kSafariGoPeedDownloadNotification = @"com.ssx.safarigopeed/download";
static NSString *const kSafariGoPeedDownloadURLKey = @"url";

#pragma mark - 越狱根目录（Dopamine / RootHide）

static NSString *JBRoot(void) {
    if ([NSFileManager.defaultManager fileExistsAtPath:@"/var/jb"]) return @"/var/jb";
    if ([NSFileManager.defaultManager fileExistsAtPath:@"/var/mobile/Mnt"]) return @"/var/mobile/Mnt";
    return @"";
}

static NSString *WorkDir(void) {
    static dispatch_once_t t;
    static NSString *dir;
    dispatch_once(&t, ^{
        dir = [JBRoot() stringByAppendingString:@"SafariGoPeed"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
    });
    return dir;
}

static NSString *LogPath(void) {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        gLogPath = [WorkDir() stringByAppendingPathComponent:@"safari_downloads.log"];
        gLock = [[NSLock alloc] init];
    });
    return gLogPath;
}

static void AppendLog(NSString *msg) {
    NSString *line = [NSString stringWithFormat:@"[%@] [%@] %@\n",
                      [NSDate date], [[NSProcessInfo processInfo] processName], msg];
    NSLog(@"[SafariGoPeed] %@", msg);
    [gLock lock];
    @try {
        NSString *lp = LogPath();
        if (![NSFileManager.defaultManager fileExistsAtPath:lp])
            [@"" writeToFile:lp atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:lp];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) { }
    [gLock unlock];
}

#pragma mark - 下载特征判断

static BOOL SafariGoPeedIsDownload(NSURLRequest *req) {
    if (!req.URL) return NO;
    NSString *url = [req.URL.absoluteString lowercaseString];

    static NSArray *exts = nil;
    if (!exts) exts = @[@"ipa", @"apk", @"aab", @"zip", @"rar", @"7z",
                        @"exe", @"dmg", @"pkg", @"mp4", @"m4a", @"bin",
                        @"deb", @"whl"];
    NSString *path = [req.URL.path lowercaseString];
    for (NSString *e in exts)
        if ([path hasSuffix:[@"." stringByAppendingString:e]]) return YES;

    if ([url containsString:@"content-disposition"] || [url containsString:@"attachment"])
        return YES;

    NSDictionary *headers = req.allHTTPHeaderFields;
    NSString *disp = headers[@"Content-Disposition"];
    if (disp && [[disp lowercaseString] containsString:@"attachment"]) return YES;
    if (headers[@"Range"]) return YES;   // 断点续传通常是下载

    return NO;
}

#pragma mark - SpringBoard 横幅（best-effort）

static void SafariGoPeedBanner(NSString *text) {
    @try {
        Class c = NSClassFromString(@"SpringBoardNotificationCenter");
        if (!c) return;
        NSNotificationCenter *nc = [c performSelector:@selector(defaultCenterForSpringBoard)];
        if (!nc) return;
        NSDictionary *payload = @{
            @"com.apple.springboard.notification_level":          @"ApplicationLevel",
            @"com.apple.springboard.notification_content_title":  @"SafariGoPeed",
            @"com.apple.springboard.notification_text":           text,
            @"com.apple.springboard.notification_type":           @"3"
        };
        [nc postNotificationName:@"com.apple.springboard.postBannerNotification"
                           object:payload];
    } @catch (NSException *e) { }
}

#pragma mark - 跳转 GoPeed (iOS)  →  仅主进程调用

static NSString *SafariGoPeedGoPeedLink(NSString *urlString) {
    NSDictionary *task = @{
        @"req":  @{ @"url": urlString, @"protocol": @"http" },
        @"opts": @{
            @"name": @"",
            @"path": @"",
            @"asDefaultPath": @YES,
            @"selectFiles": @[],
            @"extra": @{ @"connections": @(GOPEED_THREADS) }
        }
    };
    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:task options:0 error:&err];
    if (!json) return nil;
    NSString *b64 = [json base64EncodedStringWithOptions:0];
    NSString *q = [b64 stringByAddingPercentEncodingWithAllowedCharacters:
                   [NSCharacterSet URLQueryAllowedCharacterSet]];
    if (!q) return nil;
    return [NSString stringWithFormat:@"gopeed:///create?params=%@", q];
}

// 跨进程去重：双进程都可能捕获到同一请求
static BOOL SafariGoPeedShouldForward(NSString *urlString) {
    unsigned hash = 0;
    for (NSUInteger i = 0; i < urlString.length; i++)
        hash = hash * 31 + (unichar)[urlString characterAtIndex:i];
    NSString *marker = [WorkDir() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@".fwd_%08x", hash]];
    @try {
        NSDictionary *attr = [NSFileManager.defaultManager
                              attributesOfItemAtPath:marker error:nil];
        NSDate *mtime = attr[NSFileModificationDate];
        if (mtime && -[mtime timeIntervalSinceNow] < -GOPEED_DEDUP_WINDOW) {
            return NO;
        }
        [@"1" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
    return YES;
}

// 【主进程 MobileSafari 专用】真正拉起 GoPeed
static void SafariGoPeedOpenInGoPeed(NSString *urlString) {
    if (!urlString.length) return;
    if (!SafariGoPeedShouldForward(urlString)) return;

    NSString *linkStr = SafariGoPeedGoPeedLink(urlString);
    AppendLog([NSString stringWithFormat:
               @"GOPEED | 主进程拉起: %@ (线程: %d)", urlString, GOPEED_THREADS]);

    NSURL *link = [NSURL URLWithString:linkStr];
    @try {
        // 注意：不能用 canOpenURL: 预判（iOS 9+ 对未声明 LSApplicationQueriesSchemes 的
        // scheme 恒返回 NO，即使 GoPeed 已装）。直接 openURL:，用 completion 判断结果。
        [UIApplication.sharedApplication openURL:link options:@{} completionHandler:^(BOOL ok) {
            AppendLog([NSString stringWithFormat:@"GOPEED | openURL 结果: %@",
                      ok ? @"成功" : @"失败（GoPeed 未安装？）"]);
            SafariGoPeedBanner(ok ? [NSString stringWithFormat:@"已送入 GoPeed（%d 线程）", GOPEED_THREADS]
                           : [NSString stringWithFormat:@"GoPeed 未响应，链接已复制: %@", urlString]);
            if (!ok) UIPasteboard.generalPasteboard.string = urlString;
        }];
    } @catch (NSException *e) {
        UIPasteboard.generalPasteboard.string = urlString;
        AppendLog(@"GOPEED | 主进程 openURL 异常，已复制链接");
    }
}

// 【主进程】收到 WebContent 广播后调用
static void SafariGoPeedHandleDownloadNotification(NSString *urlString) {
    if (!urlString.length) return;
    // 主进程里异步执行，避免阻塞通知线程
    dispatch_async(dispatch_get_main_queue(), ^{
        SafariGoPeedOpenInGoPeed(urlString);
    });
}

#pragma mark - 捕获

// 任意进程：捕获到可疑下载 URL → 若是主进程直接拉起，否则广播给主进程
static void SafariGoPeedCaptureURL(NSURL *url) {
    if (!url || !url.absoluteString.length) return;
    AppendLog([NSString stringWithFormat:@"CAPTURE | %@", url.absoluteString]);

    BOOL isMainProcess = [[NSProcessInfo processInfo].processName isEqualToString:@"MobileSafari"];

    if (isMainProcess) {
        // 主进程自己捕获到了，直接拉起（保持原有跳转语义）
        SafariGoPeedOpenInGoPeed(url.absoluteString);
    } else {
        // WebContent：把 URL 写入共享文件，再发 Darwin 通知作为“信号”。
        // 注意：Darwin 通知跨进程只广播通知名，不带 userInfo，必须用文件传 URL。
        NSString *pending = [WorkDir() stringByAppendingPathComponent:@"pending_url.txt"];
        @try {
            [url.absoluteString writeToFile:pending atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } @catch (NSException *e) { }
        CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterPostNotification(nc,
            (__bridge CFStringRef)kSafariGoPeedDownloadNotification,
            NULL, NULL, true);
        AppendLog([NSString stringWithFormat:@"BROADCAST | 已写 pending_url 并通知主进程: %@", url.absoluteString]);
    }
}

static void SafariGoPeedReport(NSURLRequest *req, NSString *kind) {
    if (!req || !req.URL) return;
    BOOL dl = [kind isEqualToString:@"DownloadTask"] || SafariGoPeedIsDownload(req);
    if (!dl) return;

    AppendLog([NSString stringWithFormat:@"%@ | %@", kind, req.URL.absoluteString]);
    SafariGoPeedCaptureURL(req.URL);
}

#pragma mark - Hooks

%hook NSURLSession

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request {
    NSURLSessionDownloadTask *t = %orig(request);
    SafariGoPeedReport(request, @"DownloadTask");
    return t;
}

- (NSURLSessionDownloadTask *)downloadTaskWithResumeData:(NSData *)resumeData {
    NSURLSessionDownloadTask *t = %orig(resumeData);
    // resumeData 里通常带 NSURLSessionResumeCurrentRequest，取 URL
    NSURL *url = nil;
    @try {
        id req = [resumeData valueForKey:@"NSURLSessionResumeCurrentRequest"];
        if ([req isKindOfClass:[NSURLRequest class]]) url = [(NSURLRequest *)req URL];
    } @catch (NSException *e) { }
    if (url) SafariGoPeedReport([NSURLRequest requestWithURL:url], @"ResumeTask");
    return t;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    NSURLSessionDataTask *t = %orig(request);
    SafariGoPeedReport(request, @"DataTask");
    return t;
}

%end

%hook NSURLSessionTask

- (void)resume {
    NSURLRequest *req = self.originalRequest ?: self.currentRequest;
    SafariGoPeedReport(req, @"Resume");
    %orig;
}

%end

#pragma mark - 主进程监听（仅 MobileSafari 注册）

static void SafariGoPeedDownloadCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object,
                                   CFDictionaryRef userInfo) {
    // Darwin 通知不带 userInfo，URL 在共享文件 pending_url.txt 里，读出来并清除。
    NSString *pending = [WorkDir() stringByAppendingPathComponent:@"pending_url.txt"];
    NSString *url = nil;
    @try {
        url = [NSString stringWithContentsOfFile:pending encoding:NSUTF8StringEncoding error:nil];
        [NSFileManager.defaultManager removeItemAtPath:pending error:nil];
    } @catch (NSException *e) { }
    SafariGoPeedHandleDownloadNotification(url);
}

%ctor {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName];
        AppendLog([NSString stringWithFormat:@"[SafariGoPeed] v1.3 loaded in %@ (jbRoot: %@)",
                   proc, JBRoot()]);

        // 主进程注册 Darwin 监听，接收 WebContent 广播后拉起 GoPeed
        if ([proc isEqualToString:@"MobileSafari"]) {
            CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
            CFNotificationCenterAddObserver(nc, NULL,
                SafariGoPeedDownloadCallback,
                (__bridge CFStringRef)kSafariGoPeedDownloadNotification,
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            AppendLog(@"[SafariGoPeed] MobileSafari 已注册 Darwin 监听");
        }
    }
}