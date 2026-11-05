# Codex Usage

macOS 菜单栏用量监控器：

- Codex：调用本机 `codex app-server` 登录 ChatGPT，并显示 5 小时与周额度的剩余百分比及各自的重置时间。
- 支持浏览器登录和设备码登录；Codex 凭据仍由 Codex CLI 自己管理。
- 应用不读取或保存 Codex / ChatGPT 登录凭据。

## 运行

需要 macOS 14+、Swift 6，以及已安装的 Codex CLI。

```bash
cd codex-kimi-usage
swift run
```

首次启动后，点击菜单栏的 `C --`：可直接登录 Codex；在“设置”中还可以选择设备码登录。

## 构建

```bash
./scripts/build-app.sh
open "Build/Codex Usage.app"
```

Codex 数据会在应用启动时读取一次，不会定时自动获取；点击“立即刷新”，或把鼠标移入 MacBook 刘海区域，可再次读取。鼠标在刘海处停留约 0.4 秒后，会在刘海下方展示当前用量浮窗；移开即自动隐藏。进入刷新有 15 秒冷却时间，刷新时菜单栏会短暂显示 `C ↻`。若 Codex CLI 更新后 app-server 协议改变，菜单栏会显示读取错误而不会展示估算值。
