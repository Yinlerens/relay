# Relay

零遥测、自托管的多 Agent ACP 控制面与纯原生 SwiftUI iOS 客户端（支持 `Antigravity CLI`、`CodeBuddy CLI` 及任意标准 ACP Agent）。

## 目录结构

- `server/`：Node.js 22 + TypeScript + Fastify + WebSocket + SQLite（`node:sqlite`）服务端控制面，默认自动通过全部工具权限请求（`session/request_permission`）。
- `ios/`：100% 原生 SwiftUI iOS 客户端（支持 iOS 17+，在 iOS 26 / Xcode 26 上自动启用 Liquid Glass 材质），由 `XcodeGen` 生成工程，不含任何 WebView / PWA。
- `.github/workflows/build-ios-ipa.yml`：GitHub Actions `macos-latest` 自动编译未签名 `.ipa`（供 SideStore / AltStore 安装）。

## 添加自定义 ACP Agent

编辑服务端 `/opt/relay/agents.json`（参考 `server/agents.example.json`），增加一条带 `command` 与 `args` 的配置并重启 `relay.service` 即可。

## 在 iPhone 上安装与自动更新原生 App（无 Mac / 无开发者账号）

1. 将本仓库推到 GitHub（公开仓库使用标准 `macos-latest` Runner 免费不限时；推送改动 `ios/**` 会自动触发编译并发布到 `latest` Release）。
2. **SideStore / Feather 软件源地址**：
   ```text
   https://github.com/Yinlerens/relay/releases/download/latest/source.json
   ```
   在手机端 **SideStore → Sources → `+`** 添加上述软件源即可一键安装并在后续自动接收更新提醒。
3. 首次打开填入服务端地址与 `RELAY_TOKEN` 后将自动保存在系统 Keychain 中，后续同签名覆盖更新无需重复配对。
