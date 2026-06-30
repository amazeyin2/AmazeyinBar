# GPT Usage Bar

一个运行在 macOS 状态栏中的小工具，用来显示多个 GPT 账号的用量。

现在额度查询走的是 ChatGPT 官方侧接口：

- `GET https://chatgpt.com/backend-api/wham/usage`

不再依赖 `sub.amazeyin.com/api/v1/admin/accounts/:id/usage` 这类二次封装接口。

现在也支持作为一个本地 webhook 接收器运行：

- 其他服务向你的 Mac 发 HTTP 请求
- App 在桌面弹出系统通知
- 适合 Jenkins、脚本、内网服务、自动化任务完成后提醒

## 已实现

- 菜单栏显示多账号 5 小时或 7 天利用率
- 下拉菜单展示每个账号的 5H / 7D 利用率和重置时间
- 定时自动刷新
- 配置文件外置，不把 token 写进源码
- 一键重新加载配置与手动刷新
- 从当前 Chrome 的 Sub2API 后台导入 OpenAI OAuth 凭证，并直接查询 ChatGPT backend-api
- 本地监听 webhook 并在 macOS 桌面弹通知

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
open dist/AmazeyinBar.app
```

## 更新 App 图标

```bash
cd /Users/yin/tools/codex-workspace/amazeyin/gpt-usage-menubar
chmod +x scripts/make-icon.sh
./scripts/make-icon.sh /path/to/icon-source.jpg
./scripts/build-app.sh
```

## 从当前 Chrome 自动导入账号

前提：
- 你已经在 Chrome 登录 `sub.amazeyin.com`
- 当前打开着 `https://sub.amazeyin.com/admin/accounts`
- Chrome 允许远程调试连接

执行：

```bash
cd /Users/yin/tools/codex-workspace/amazeyin/gpt-usage-menubar
node ./scripts/import-from-chrome.mjs
```

只看导入结果、不落盘：

```bash
node ./scripts/import-from-chrome.mjs --dry-run
```

这个脚本/应用内导入会自动：
- 从当前账号管理页抓取账号列表
- 从页面真实请求里抓取当前 admin `authorization`
- 调用 Sub2API 管理端导出接口获取每个 OpenAI OAuth 账号的 `access_token` / `chatgpt_account_id`
- 把可直接查询 ChatGPT 的账号写入 `~/Library/Application Support/GPTUsageBar/config.json`

## 配置示例

```json
{
  "refreshIntervalSeconds": 300,
  "titleMode": "fiveHour",
  "webhook": {
    "enabled": true,
    "bindAddress": "0.0.0.0",
    "path": "/notify",
    "port": 8787,
    "token": "REPLACE_WITH_WEBHOOK_TOKEN"
  },
  "accounts": [
    {
      "id": 3,
      "name": "主账号",
      "baseURL": "https://sub.amazeyin.com",
      "accessToken": "替换成 OpenAI access token",
      "chatgptAccountId": "替换成 chatgpt account id",
      "fedRAMP": false,
      "enabled": true
    },
    {
      "id": 8,
      "name": "备用号",
      "baseURL": "https://sub.amazeyin.com",
      "accessToken": "替换成 OpenAI access token",
      "chatgptAccountId": "替换成 chatgpt account id",
      "fedRAMP": false,
      "enabled": true
    }
  ]
}
```

## Webhook 用法

默认 webhook 地址格式：

`http://你的Mac局域网IP:8787/notify?token=你的token`

推荐请求体：

```bash
curl -X POST "http://你的Mac局域网IP:8787/notify?token=你的token" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Jenkins",
    "subtitle": "构建完成",
    "message": "deploy-prod 执行成功"
  }'
```

也支持更简单的纯文本：

```bash
curl -X POST "http://你的Mac局域网IP:8787/notify?token=你的token" \
  -H "Content-Type: text/plain; charset=utf-8" \
  -d '任务完成'
```

支持的字段：

- `title`: 通知标题
- `subtitle`: 通知副标题
- `message` 或 `body`: 通知正文
- `sound`: 是否播放声音，默认 `true`

认证方式支持三种，任选其一：

- Query：`?token=xxx`
- Header：`token: xxx`
- Header：`Authorization: Bearer xxx`

健康检查：

```bash
curl "http://你的Mac局域网IP:8787/notify?token=你的token"
```

旧版只有 `authorization` 的配置还能被读取，但已经不能直接查额度；重新执行一次“从当前 Chrome 导入账号”就会补齐新字段。

## 菜单栏标题模式

- `fiveHour`: 每个账号显示 5 小时利用率
- `sevenDay`: 每个账号显示 7 天利用率
- `compact`: 只显示成功获取到数据的账号数量
