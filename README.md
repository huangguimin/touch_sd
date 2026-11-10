# Touch SD

Touch SD 指纹卡的 macOS App。卡插在 Mac 的 SD 卡槽里，按指纹就能打开加密保险箱、在终端里代替 sudo 密码、给 SSH 和 Git 签名、在锁屏界面输入登录密码，手指沿卡边滑动还能滚动网页、调音量。

## 下载安装

1. 到 [Releases](https://github.com/huangguimin/touch_sd/releases) 下载最新的 `Touch SD.dmg`，打开后把 Touch SD 拖进“应用程序”。
2. 第一次打开时系统会提示无法验证开发者：App 没有经过 Apple 公证。打开“系统设置 > 隐私与安全性”，在页面下方点“仍要打开”。
3. 插卡，按 App 的提示配对：核对卡上灯的颜色和 App 显示的一致。
4. 在“指纹”页录入手指。滚动页面、自动键入和锁屏输入密码需要“辅助功能”权限，App 会引导你打开。

需要 macOS 13 或更新版本，Apple 芯片和 Intel 都支持；sudo 指纹需要 macOS 14 或更新版本。

App 用的是不带开发者身份的签名，所以每次升级 App 后，系统会重新询问“辅助功能”权限和钥匙串访问，再允许一次即可。

## 功能

| 页面 | 做什么 |
| --- | --- |
| 指纹 | 录入多根手指；识别成功时自动补充样本，越用越准 |
| 保险箱 | 存密码、密钥。打开要同时满足：这台 Mac、配对的卡插着、真的按了传感器、按的是录入过的手指 |
| 解锁动作 | 识别通过后执行：锁屏时输入登录密码、输入两步验证码、自动键入文字、打开应用或网址、运行快捷指令或 shell 命令 |
| sudo | 终端里用 sudo 时按指纹代替密码；卡不在或识别不通过时照常问密码 |
| SSH 与确认 | 内置 SSH Agent，密钥由卡派生、取不出来，每次签名都要按一下；脚本可以用 `fingerconfirm "原因"` 要求按指纹 |
| 滑动控制 | 滚动网页、调音量、视频快进、演示翻页、屏幕亮度、切换曲目 |
| 设备 | 卡的身份和固件版本、在 App 里升级固件、恢复出厂、拔卡锁屏 |

## 安全

指纹只以加密形式保存在你的 Mac 上，卡上不存指纹，也不联网；加密文件要这张卡和这台 Mac 一起才能解开，拔卡后立即从内存清除。卡和 App 之间的每条消息都用 ChaCha20-Poly1305 加密认证。

能防住什么、防不住什么，见 App 里的“安全说明”页和 [docs/SECURITY_DESIGN.md](docs/SECURITY_DESIGN.md)。卡和 App 之间的通信协议见 [docs/CARD_PROTOCOL.md](docs/CARD_PROTOCOL.md)。

## 从源码编译

需要 Xcode 命令行工具、CMake 和 Ninja（`brew install cmake ninja`）。

```sh
scripts/build_opencv.sh     # 第一次：编 OpenCV 5.0.0 静态库到 vendor/opencv（arm64 + x86_64）
scripts/build_app.sh        # 编 App 和 sudo 用的 PAM 模块，打包到 dist/Touch SD.app 和 dist/Touch SD.dmg
```

签名默认用钥匙串里第一个 “Apple Development” 证书，没有就用不带身份的签名；也可以用 `SIGN_ID=...` 指定。

| 目录 | 内容 |
| --- | --- |
| `Sources/CvBridge` | OpenCV 的 Objective-C++ 桥：质量判断、特征比对 |
| `Sources/FingerCore` | 卡的通信协议、加密通道、钥匙串、加密指纹库、录入和识别、固件升级 |
| `Sources/FingerUI` | 滑动控制：网页滚动、音量、音效 |
| `Sources/SDFinger` | App 本体 |
| `Sources/fingerconfirm` | 让脚本要求按指纹的命令行工具 |
| `pam/` | sudo 的 PAM 模块 |

数据位置：`~/Library/Application Support/SD Finger/`（加密指纹库、保险箱），以及钥匙串里服务名为 “SD Finger” 的条目（产品改名前的名字，为了不丢已有的配对保留了下来）。

## 许可证

[GPL-3.0](LICENSE)
