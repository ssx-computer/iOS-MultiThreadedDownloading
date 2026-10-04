// SDFSpy - 捕获 Safari 的所有下载请求 → 自动跳转 GoPeed (iOS) 8线程下载
// 兼容 Dopamine / RootHide（越狱根目录 /var/jb 自适应）
// 注入进程：MobileSafari + com.apple.WebKit.WebContent

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *gLogPath = nil;
static NSLock   *gLock = nil;

// 跳转到 GoPeed 使用的线程数（HTTP 连接数）
static const int GOPEED_THREADS = 8;
// 同一 URL 的去重窗口（秒）—— 主进程与 WebContent 双进程都会 hook 到，避免重复跳转
static const double GOPEED_DEDUP_WINDOW = 10.0;

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
        dir = [JBRoot() stringByAppendingString:@"SDFSpy"];
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
                      [NSDate date], [NSProcessInfo.processInfo.processName], msg];
    NSLog(@"[SDFSpy] %@", msg);
    [gLock lock];
    @try {
        if (![NSFileManager.defaultManager fileExistsAtPath:LogPath()])
            [@"" writeToFile:LogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LogPath()];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) { }
    [gLock unlock];
}

#pragma mark - 下载特征判断

static BOOL SDFSpyIsDownload(NSURLRequest *req) {
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

static void SDFSpyBanner(NSString *text) {
    @try {
        Class c = NSClassFromString(@"SpringBoardNotificationCenter");
        if (!c) return;
        NSNotificationCenter *nc = [c performSelector:@selector(defaultCenterForSpringBoard)];
        if (!nc) return;
        NSDictionary *payload = @{
            @"com.apple.springboard.notification_level":          @"ApplicationLevel",
            @"com.apple.springboard.notification_content_title":  @"SDFSpy",
            @"com.apple.springboard.notification_text":           text,
            @"com.apple.springboard.notification_type":           @"3"
        };
        [nc postNotificationName:@"com.apple.springboard.postBannerNotification"
                           object:payload];
    } @catch (NSException *e) { }
}

#pragma mark - 跳转 GoPeed (iOS)
//
// GoPeed 官方 URL Scheme（来自 GopeedLab/gopeed 仓库 ui/flutter 的
// app_deep_link_controller.dart 与官方文档站）：
//
//   gopeed:///create?params=<base64(json)>
//
// json = CreateTask:
//   {
//     "req":  { "url": "...", "protocol": "http" },
//     "opts": { "name": "", "path": "", "asDefaultPath": true,
//               "selectFiles": [],
//               "extra": { "connections": 8 } }     // ← 8 线程
//   }
//
// 解码过程：base64 → utf8 → jsonDecode → CreateTask.fromJson

static NSString *SDFSpyGoPeedLink(NSString *urlString) {
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

    NSString *b64 = [json base64EncodedStringWithOptions:0];   // 标准 base64（+ / =）
    NSString *q = [b64 stringByAddingPercentEncodingWithAllowedCharacters:
                   [NSCharacterSet URLQueryAllowedCharacterSet]];
    if (!q) return nil;
    return [NSString stringWithFormat:@"gopeed:///create?params=%@", q];
}

// 跨进程去重：双进程都可能 hook 到同一请求，用标记文件 + 时间窗口去重
static BOOL SDFSpyShouldForward(NSString *urlString) {
    unsigned hash = 0;
    for (unichar c in urlString) hash = hash * 31 + c;
    NSString *marker = [WorkDir() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@".fwd_%08x", hash]];
    @try {
        NSDictionary *attr = [NSFileManager.defaultManager
                              attributesOfItemAtPath:marker error:nil];
        NSDate *mtime = attr[NSFileModificationDate];
        if (mtime && -[mtime timeIntervalSinceNow] < -GOPEED_DEDUP_WINDOW) {
            return NO;   // 窗口内已转发过
        }
        [@"1" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
    return YES;
}

static void SDFSpyForwardToGoPeed(NSURL *url) {
    if (!url) return;
    NSString *u = url.absoluteString;

    if (!SDFSpyShouldForward(u)) return;

    NSString *linkStr = SDFSpyGoPeedLink(u);
    AppendLog([NSString stringWithFormat:
               @"GOPEED | 跳转: %@ (线程: %d)", u, GOPEED_THREADS]);

    NSURL *link = [NSURL URLWithString:linkStr];
    @try {
        [UIApplication.sharedApplication openURL:link
                                       options:@{}
                              completionHandler:^(BOOL success) {
            AppendLog([NSString stringWithFormat:@"GOPEED | 跳转结果: %@",
                      success ? @"成功" : @"失败（GoPeed 未安装？）"]);
            if (success)
                SDFSpyBanner([NSString stringWithFormat:@"已送入 GoPeed（%d 线程）", GOPEED_THREADS]);
            else
                SDFSpyBanner([NSString stringWithFormat:@"GoPeed 未响应，链接已复制: %@", u]);
        }];
    } @catch (NSException *e) {
        UIPasteboard.generalPasteboard.string = u;
        AppendLog(@"GOPEED | openURL 异常，已复制链接到剪贴板");
        SDFSpyBanner(@"GoPeed 未响应，链接已复制到剪贴板");
    }
}

#pragma mark - 上报

static void SDFSpyReport(NSURLRequest *req, NSString *kind) {
    if (!req || !req.URL) return;
    BOOL dl = [kind isEqualToString:@"DownloadTask"] || SDFSpyIsDownload(req);
    if (!dl) return;      // 普通资源请求不记录、不转发

    NSString *msg = [NSString stringWithFormat:@"%@ | %@ | %@",
                     kind, req.URL.absoluteString,
                     (req.allHTTPHeaderFields[@"User-Agent"] ?: @"-")];
    AppendLog(msg);
    SDFSpyForwardToGoPeed(req.URL);
}

#pragma mark - Hooks

%hook NSURLSession

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request {
    NSURLSessionDownloadTask *t = %orig(request);
    SDFSpyReport(request, @"DownloadTask");
    return t;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    NSURLSessionDataTask *t = %orig(request);
    SDFSpyReport(request, @"DataTask");
    return t;
}

%end

%hook NSURLSessionTask

- (void)resume {
    NSURLRequest *req = self.originalRequest ?: self.currentRequest ?: self.request;
    SDFSpyReport(req, @"Resume");
    %orig;
}

%end

%%ctor {
    NSLog(@"[SDFSpy] v1.1 loaded in %@ (jbRoot: %@, gopeedThreads: %d)",
          NSProcessInfo.processInfo.processName, JBRoot(), GOPEED_THREADS);
}
