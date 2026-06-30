#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const DEFAULT_CONFIG_PATH = path.join(
  os.homedir(),
  "Library/Application Support/GPTUsageBar/config.json",
);
const DEFAULT_TARGET_URL = "https://sub.amazeyin.com/admin/accounts";

function parseArgs(argv) {
  const args = {
    config: DEFAULT_CONFIG_PATH,
    url: DEFAULT_TARGET_URL,
    dryRun: false,
  };

  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--dry-run") {
      args.dryRun = true;
    } else if (arg === "--config" && argv[i + 1]) {
      args.config = argv[++i];
    } else if (arg === "--url" && argv[i + 1]) {
      args.url = argv[++i];
    } else {
      throw new Error(`未知参数: ${arg}`);
    }
  }
  return args;
}

function readConfig(configPath) {
  if (!fs.existsSync(configPath)) {
    return {
      refreshIntervalSeconds: 300,
      titleMode: "fiveHour",
      importOptions: {
        chromeAccountsURL: DEFAULT_TARGET_URL,
        includePlatforms: ["openai"],
        includeDisabledAccounts: false,
      },
      accounts: [],
    };
  }
  return JSON.parse(fs.readFileSync(configPath, "utf8"));
}

function discoverChromeDebugger() {
  const file = path.join(
    os.homedir(),
    "Library/Application Support/Google/Chrome/DevToolsActivePort",
  );
  const content = fs.readFileSync(file, "utf8").trim().split("\n");
  return {
    port: Number(content[0]),
    wsPath: content[1],
  };
}

function createCDPClient() {
  const { port, wsPath } = discoverChromeDebugger();
  const ws = new WebSocket(`ws://127.0.0.1:${port}${wsPath}`);
  let id = 0;
  const pending = new Map();
  const sessions = new Map();

  const api = {
    ws,
    sessions,
    async connect() {
      await new Promise((resolve, reject) => {
        ws.addEventListener("open", resolve, { once: true });
        ws.addEventListener("error", reject, { once: true });
      });
    },
    async send(method, params = {}, sessionId = null, timeoutMs = 15000) {
      const msgId = ++id;
      return await new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(msgId);
          reject(new Error(`CDP timeout: ${method}`));
        }, timeoutMs);
        pending.set(msgId, { resolve, reject, timer });
        const payload = { id: msgId, method, params };
        if (sessionId) payload.sessionId = sessionId;
        ws.send(JSON.stringify(payload));
      });
    },
    close() {
      try {
        ws.close();
      } catch {}
    },
  };

  ws.addEventListener("message", (event) => {
    const msg = JSON.parse(event.data.toString());
    if (msg.method === "Target.attachedToTarget" && msg.params?.targetInfo?.targetId) {
      sessions.set(msg.params.targetInfo.targetId, msg.params.sessionId);
      return;
    }
    if (!msg.id || !pending.has(msg.id)) return;
    const { resolve, reject, timer } = pending.get(msg.id);
    clearTimeout(timer);
    pending.delete(msg.id);
    if (msg.error) reject(new Error(JSON.stringify(msg.error)));
    else resolve(msg.result);
  });

  return api;
}

async function sleep(ms) {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function findAccountsTarget(client, targetURL) {
  const result = await client.send("Target.getTargets");
  const target = result.targetInfos.find(
    (item) => item.type === "page" && item.url?.startsWith(targetURL),
  );
  if (!target) {
    throw new Error(`没有找到已打开的账号管理页面: ${targetURL}`);
  }
  return target.targetId;
}

async function ensureSession(client, targetId) {
  if (client.sessions.has(targetId)) return client.sessions.get(targetId);
  const attached = await client.send("Target.attachToTarget", { targetId, flatten: true });
  client.sessions.set(targetId, attached.sessionId);
  return attached.sessionId;
}

async function captureAccountsAndAuth(client, sessionId) {
  const requests = [];
  const requestMeta = new Map();
  const responseBodies = [];

  const onMessage = async (event) => {
    const msg = JSON.parse(event.data.toString());
    if (msg.sessionId !== sessionId) return;

    if (msg.method === "Network.requestWillBeSent") {
      requestMeta.set(msg.params.requestId, {
        url: msg.params.request.url,
        method: msg.params.request.method,
      });
    }

    if (msg.method === "Network.requestWillBeSentExtraInfo") {
      const meta = requestMeta.get(msg.params.requestId) || {};
      const headers = Object.fromEntries(
        Object.entries(msg.params.headers || {}).map(([k, v]) => [k.toLowerCase(), v]),
      );
      if (headers.authorization) {
        requests.push({
          url: meta.url || null,
          method: meta.method || null,
          authorization: headers.authorization || null,
          cookie: headers.cookie || null,
          referer: headers.referer || null,
        });
      }
    }

    if (msg.method === "Network.responseReceived") {
      const meta = requestMeta.get(msg.params.requestId) || {};
      if (!meta.url?.includes("/api/v1/admin/accounts")) return;
      try {
        const body = await client.send(
          "Network.getResponseBody",
          { requestId: msg.params.requestId },
          sessionId,
        );
        responseBodies.push({ url: meta.url, body: body.body });
      } catch {}
    }
  };

  client.ws.addEventListener("message", onMessage);
  try {
    await client.send("Page.enable", {}, sessionId);
    await client.send("Network.enable", {}, sessionId);
    await client.send("Runtime.enable", {}, sessionId);
    await client.send("Page.reload", { ignoreCache: false }, sessionId);
    await sleep(5000);
  } finally {
    client.ws.removeEventListener("message", onMessage);
  }

  const auth = requests.find((item) => item.authorization)?.authorization ?? null;
  const cookie = requests.find((item) => item.cookie)?.cookie ?? "";
  const accountListResponse = responseBodies.find((item) =>
    item.url.includes("/api/v1/admin/accounts?page="),
  );

  if (!auth || !accountListResponse) {
    throw new Error("未能从当前页面流量中抓到 authorization 或账号列表");
  }

  const parsed = JSON.parse(accountListResponse.body);
  return {
    authorization: auth,
    cookie,
    accounts: parsed.data?.items ?? [],
  };
}

async function fetchAccountSecrets(baseURL, captured, accountId) {
  const url = new URL("/api/v1/admin/accounts/data", baseURL);
  url.searchParams.set("ids", String(accountId));
  url.searchParams.set("include_proxies", "false");

  const response = await fetch(url, {
    headers: {
      accept: "application/json, text/plain, */*",
      "accept-language": "zh",
      authorization: captured.authorization,
      referer: `${baseURL}/admin/accounts`,
      ...(captured.cookie ? { cookie: captured.cookie } : {}),
    },
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`账号 #${accountId} 导出失败: HTTP ${response.status} ${body}`);
  }

  const parsed = await response.json();
  const account = parsed.data?.accounts?.[0];
  const credentials = account?.credentials ?? {};
  const accessToken = typeof credentials.access_token === "string" ? credentials.access_token.trim() : "";
  const chatgptAccountId =
    typeof credentials.chatgpt_account_id === "string"
      ? credentials.chatgpt_account_id.trim()
      : typeof credentials.organization_id === "string"
        ? credentials.organization_id.trim()
        : "";

  if (!accessToken || !chatgptAccountId) {
    return null;
  }

  return {
    accessToken,
    chatgptAccountId,
    fedRAMP: credentials.chatgpt_account_is_fedramp === true,
  };
}

async function buildImportedAccounts(config, captured, pageURL) {
  const baseURL = new URL(pageURL).origin;
  const includePlatforms = new Set(
    config.importOptions?.includePlatforms?.map((item) => String(item).toLowerCase()) ?? ["openai"],
  );
  const includeDisabledAccounts = Boolean(config.importOptions?.includeDisabledAccounts);

  const visibleAccounts = captured.accounts
    .filter((account) => includePlatforms.has(String(account.platform).toLowerCase()))
    .filter((account) => includeDisabledAccounts || account.status === "active");

  const importedAccounts = [];
  for (const account of visibleAccounts) {
    const secrets = await fetchAccountSecrets(baseURL, captured, account.id);
    if (!secrets) continue;
    importedAccounts.push({
      id: account.id,
      name: account.name,
      baseURL,
      accessToken: secrets.accessToken,
      chatgptAccountId: secrets.chatgptAccountId,
      fedRAMP: secrets.fedRAMP,
      enabled: true,
    });
  }
  return importedAccounts;
}

function mergeAccounts(existingAccounts, importedAccounts) {
  const merged = new Map(existingAccounts.map((account) => [account.id, account]));
  for (const account of importedAccounts) {
    merged.set(account.id, { ...merged.get(account.id), ...account });
  }
  return [...merged.values()].sort((a, b) => a.id - b.id);
}

async function main() {
  const args = parseArgs(process.argv);
  const config = readConfig(args.config);
  const targetURL = config.importOptions?.chromeAccountsURL || args.url;
  const client = createCDPClient();

  try {
    await client.connect();
    const targetId = await findAccountsTarget(client, targetURL);
    const sessionId = await ensureSession(client, targetId);
    const captured = await captureAccountsAndAuth(client, sessionId);
    const importedAccounts = await buildImportedAccounts(config, captured, targetURL);

    const nextConfig = {
      ...config,
      accounts: mergeAccounts(config.accounts ?? [], importedAccounts),
    };

    if (!args.dryRun) {
      fs.mkdirSync(path.dirname(args.config), { recursive: true });
      fs.writeFileSync(args.config, `${JSON.stringify(nextConfig, null, 2)}\n`);
    }

    const summary = {
      configPath: args.config,
      dryRun: args.dryRun,
      importedCount: importedAccounts.length,
      accountNames: importedAccounts.map((account) => `${account.id}:${account.name}`),
    };
    console.log(JSON.stringify(summary, null, 2));
  } finally {
    client.close();
  }
}

main().catch((error) => {
  console.error(error.message || String(error));
  process.exit(1);
});
