# SDFSpy — iOS Safari 下载请求捕获插件

捕获 Safari 发出的**所有下载类网络请求**（显式 `downloadTask`、带下载特征的 `dataTask`、`resume` 的 task），
记录到越狱根目录日志文件，并尝试弹 SpringBoard 横幅通知。

- ✅ 兼容 **Dopamine / RootHide**：自动检测 `/var/jb` 越狱根目录
- ✅ 同时注入 `com.apple.mobilesafari`（Safari 主进程）和
  `com.apple.WebKit.WebContent`（WebKit 资源加载进程），双进程覆盖，不漏抓
- ✅ 纯 ObjC hook `NSURLSession`，不依赖任何私有 Substrate API

## 捕获范围

| 类型 | 处理 |
|---|---|
| `downloadTaskWithRequest:` | **必定记录**（这是 Safari/应用的显式下载入口） |
| `dataTaskWithRequest:` / `resume` | URL 带下载扩展名（ipa/apk/zip/dmg/exe/…）、`Content-Disposition: attachment`、`Range` 断点续传头 → 记录 |

## 捕获后自动跳转 GoPeed（iOS）+ 8 线程

识别为下载后，插件通过 GoPeed **官方 URL Scheme** 直接拉起 GoPeed iOS App：

```
gopeed:///create?params=<base64(CreateTask JSON)>
```

参数来自 GoPeed 主仓库（`GopeedLab/gopeed`）的 `ui/flutter/lib/app/application/app_deep_link_controller.dart`：

```json
{
  "req":  { "url": "https://example.com/file.zip", "protocol": "http" },
  "opts": {
    "name": "", "path": "", "asDefaultPath": true, "selectFiles": [],
    "extra": { "connections": 8 }        ← HTTP 8 线程/连接
  }
}
```

- GoPeed 收到后会打开「新建任务」页，URL 与 8 线程参数已填好，点一下「添加」即开始下载
- 双进程（MobileSafari + WebContent）都 hook 到同一请求时，用 10 秒去重窗口防止重复拉起
- 若 GoPeed 未安装：链接自动复制到剪贴板，日志里会记录失败原因

**前提**：设备已安装 GoPeed iOS 版（App Store / 官网分发，本地 server 模式即可，无需远程 server）。

可调项：`Tweak.x` 顶部 `GOPEED_THREADS`（默认 8）、`GOPEED_DEDUP_WINDOW`。

日志位置（Dopamine/RootHide）：`/var/jb/SDFSpy/safari_downloads.log`
传统越狱：`/SDFSpy/safari_downloads.log`
可用 MobileTerminal 里 `cat /var/jb/SDFSpy/safari_downloads.log` 查看，或用内置文件管理 App 直接读。

## 构建（需要 macOS）

本机开发机（Windows）无法直接编译 iOS tweak，请在 **macOS + Docker** 上构建：

```bash
cd SDFSpy
./build.sh          # 自动拉 xcodeorg/xcode:16.5 镜像 + Theos，make package
```

产物：`_Packages/arm64/com.ssx.sdfsafari.spy_1.1.0_arm64.deb`

> 如果目标设备系统低于 17（如 15/16），把 Makefile 中 `TARGET := iphone:clang:16.5:17.0`
> 改成对应 SDK 版本（如 `15.0`）。

## 安装

方式一（Sileo，推荐，自动装到 /var/jb 越狱根）：

```bash
scp _Packages/arm64/*.deb User@你的设备IP:~/
# 设备上用 Sileo / 自带文件管理器安装 deb
```

方式二（SSH）：

```bash
make install THEOS_DEVICE_IP=你的设备IP
```

装完**杀进程重进 Safari**（杀掉 WebContent 和 MobileSafari）即可生效。

## 验证

1. Safari 里下载任意 `.ipa`/`.zip`（或访问会返回 `Content-Disposition: attachment` 的地址）
2. MobileTerminal：`tail -f /var/jb/SDFSpy/safari_downloads.log`

## 可调项（Tweak.x）

- `gBannerEnabled`：是否每个下载都弹横幅
- `SDFSpyReport` 里 `if (!dl) return;`：改成始终 `AppendLog` 可**记录全部请求**（日志量大，慎用）
- `exts` 数组：扩展下载识别的文件扩展名

## RootHide / Dopamine 注意

- 不要用 `make install` 手动装到系统根；走 Sileo 安装会自动落在 `/var/jb` 下，
  且 Substrate（elastic/preposition）在 Dopamine 上会处理 dyld 缓存注入，无需额外配置。
- 日志目录写在越狱根下，不会触发 RootHide 的隐藏保护；如需对隐藏 App 进一步遮蔽日志文件，
  把日志路径换到更深层目录并收紧权限即可。
