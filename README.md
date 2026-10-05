# SafariGoPeed — iOS Safari 下载请求自动转发到 GoPeed 插件

捕获 Safari 发出的**所有下载类网络请求**，通过 GoPeed 官方 URL Scheme 自动拉起 GoPeed iOS App，
并以 **8 线程（8 个 HTTP 连接）** 开始下载。

- ✅ 兼容 **Dopamine / RootHide**：自动检测 `/var/jb` 越狱根目录（rootless 包）
- ✅ 同时注入 `com.apple.mobilesafari`（Safari 主进程）和
  `com.apple.WebKit.WebContent`（WebKit 网络/下载进程），双进程覆盖不漏抓
- ✅ 纯 ObjC hook `NSURLSession`，不依赖任何私有 Substrate API
- ✅ 跨进程跳转：WebContent 捕获到下载 → 共享文件 + Darwin 通知 → 主进程 MobileSafari 拉起 GoPeed

## 捕获范围

| 类型 | 处理 |
|---|---|
| `downloadTaskWithRequest:` / `downloadTaskWithResumeData:` | **必定记录**（显式下载入口） |
| `dataTaskWithRequest:` / `resume` | URL 带下载扩展名（ipa/apk/zip/dmg/exe/…）、`Content-Disposition: attachment`、`Range` 断点续传头 → 记录 |

## 跳转 GoPeed（iOS）+ 8 线程

识别为下载后，通过 GoPeed **官方 URL Scheme** 拉起 GoPeed iOS App：

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

日志位置（Dopamine/RootHide）：`/var/jb/SafariGoPeed/safari_downloads.log`
传统越狱：`/SafariGoPeed/safari_downloads.log`
可用 MobileTerminal 里 `cat /var/jb/SafariGoPeed/safari_downloads.log` 查看，或用内置文件管理 App 直接读。

## 构建（CI）

仓库已配置 **GitHub Actions** 自动构建：push 到 `main` 后，在 Actions 里下载
`SafariGoPeed-main` artifact（`packages/*.deb`）即可。也可本地用 `./build.sh`（macOS + Docker）。

产物：`packages/com.ssx.safarigopeed_1.3.0_iphoneos-arm64.deb`

> 构建机 SDK 会自动选择（`TARGET := iphone:clang::17.0`，SDK 段留空 → 用机器最新 SDK）。
> 如目标设备系统低于 17，可把最后的 `17.0` 改成目标系统版本（如 `15.0`）。

## 安装（Dopamine / RootHide）

方式一（Sileo / 文件管理器，推荐，自动装到 /var/jb 越狱根）：

```bash
scp packages/*.deb User@你的设备IP:~/
# 设备上用 Sileo / 自带文件管理器安装 deb
```

方式二（SSH）：

```bash
make install THEOS_DEVICE_IP=你的设备IP
```

装完**杀进程重进 Safari**（杀掉 WebContent 和 MobileSafari）即可生效。

## 验证

1. Safari 里下载任意 `.ipa`/`.zip`（或访问会返回 `Content-Disposition: attachment` 的地址）
2. MobileTerminal：`tail -f /var/jb/SafariGoPeed/safari_downloads.log`
3. 应看到 `CAPTURE` → `BROADCAST` → `GOPEED | 主进程拉起` 日志，然后 GoPeed 自动弹出

## 可调项（Tweak.x）

- `GOPEED_THREADS`：GoPeed 下载线程数（默认 8）
- `SafariGoPeedReport` 里 `if (!dl) return;`：改成始终 `AppendLog` 可**记录全部请求**（日志量大，慎用）
- `exts` 数组：扩展下载识别的文件扩展名

## RootHide / Dopamine 注意

- 本包为 **rootless**（`THEOS_PACKAGE_SCHEME=rootless`），装到 `/var/jb` 下，
  Substrate（elastic/preposition）在 Dopamine 上会处理 dyld 缓存注入，无需额外配置。
- 日志目录写在越狱根下，不会触发 RootHide 的隐藏保护；如需对隐藏 App 进一步遮蔽日志文件，
  把日志路径换到更深层目录并收紧权限即可。