# Codex / Grok 用量条

macOS 菜单栏用量看板：一个圆环显示当前账号剩余额度，点开查看多账号周额度。

## 功能

- **菜单栏额度条**：彩色圆环 + 剩余百分比（绿 ≥50% / 橙 ≥20% / 红 <20%），颜色随余量变化。
- **多账号看板**：自动发现本机的 Codex 账号与多个 Grok 账号，逐个显示周额度圆环、已用比、重置倒计时。
- **点击切换**：点某个账号卡片，菜单栏圆环即切换到该账号（选择会记住）；剩余最少的账号标记「最紧张」。
- **Codex**：周额度、5 小时额度（若返回）、本周 Token、累计 Token、重置卡、近 7 天用量柱状图。
- **Grok**：周额度、GrokBuild 用量、预付余额。
- 每 5 分钟自动刷新；打开面板或点右上角刷新即时更新。

## 数据来源

- Codex：`codex app-server` 的 `account/rateLimits/read` 与 `account/usage/read`（读取当前 `CODEX_HOME`，默认 `~/.codex`）。
- Grok：`https://cli-chat-proxy.grok.com/v1/billing?format=credits`，使用 `~/.grok*/auth.json` 里的 OAuth token。
- 不写入、不上传任何密钥或令牌；只在本机读取并显示额度。

## 环境要求

- macOS 13+，Apple Silicon 或 Intel
- Xcode Command Line Tools（提供 `swiftc`）：`xcode-select --install`
- 已安装并登录对应 CLI：`codex`、`grok`

## 构建与运行

```bash
./build.sh
open "dist/Codex 用量条.app"
```

`build.sh` 用 `swiftc` 编译 `main.swift`，生成 `dist/Codex 用量条.app`（LSUIElement，无 Dock 图标，仅菜单栏）。

## 添加更多账号

- Codex：切换 `CODEX_HOME` 指向另一个含 `auth.json` 的目录。
- Grok：把另一个账号的 `GROK_HOME` 目录（含 `auth.json`）放到 `~/.grok*` 下，看板会自动按 `user_id` 去重并多显示一张卡。

## 说明

- Grok 的 OAuth token 约 2 小时过期；过期后该账号卡片提示「运行一次 grok 刷新」，正常使用 grok 会自动续期。
- 非官方项目，与 OpenAI / xAI 无关联。
