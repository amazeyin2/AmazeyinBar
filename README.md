# GPT Usage Bar

一个运行在 macOS 状态栏中的小工具，用来显示多个 GPT 账号的用量。

## 已实现

- 菜单栏显示多账号 5 小时或 7 天利用率
- 下拉菜单展示每个账号的请求数、Token 数、花费、重置时间
- 定时自动刷新
- 配置文件外置，不把 token 写进源码
- 一键重新加载配置与手动刷新

## 本地运行

```bash
cd /Users/yin/tools/codex-workspace/amazeyin/gpt-usage-menubar
swift run GPTUsageBar
```

首次启动会自动生成配置文件：

`~/Library/Application Support/GPTUsageBar/config.json`

## 打包成 `.app`

```bash
cd /Users/yin/tools/codex-workspace/amazeyin/gpt-usage-menubar
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open dist/GPTUsageBar.app
```

## 配置示例

```json
{
  "refreshIntervalSeconds": 300,
  "titleMode": "fiveHour",
  "accounts": [
    {
      "id": 3,
      "name": "主账号",
      "baseURL": "https://sub.amazeyin.com",
      "timezone": "Asia/Shanghai",
      "source": "active",
      "authorization": "Bearer 替换成你的 token",
      "cookie": "_ga=...; __stripe_mid=...",
      "enabled": true
    },
    {
      "id": 8,
      "name": "备用号",
      "baseURL": "https://sub.amazeyin.com",
      "timezone": "Asia/Shanghai",
      "source": "active",
      "authorization": "Bearer 替换成你的 token",
      "cookie": "",
      "enabled": true
    }
  ]
}
```

## 菜单栏标题模式

- `fiveHour`: 每个账号显示 5 小时利用率
- `sevenDay`: 每个账号显示 7 天利用率
- `compact`: 只显示成功获取到数据的账号数量
