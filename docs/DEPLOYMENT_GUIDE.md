# OpenClaw Arena — Telegram Web App 部署指南

> 从零到上线的完整步骤，预计耗时 30-60 分钟

---

## 架构总览

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Telegram Bot    │────▶│  Next.js App      │────▶│  Supabase       │
│  (@YourBot)      │     │  (Vercel)         │     │  (Cloud)        │
│                  │     │                   │     │                 │
│  WebApp URL ─────┼────▶│  app/page.tsx     │     │  PostgreSQL     │
│  /start command  │     │  TG SDK loaded    │     │  Edge Functions │
│  Bot API notify  │     │  iframe 嵌入 TG    │     │  Auth           │
└─────────────────┘     └──────────────────┘     └─────────────────┘
```

**你需要准备:**
- Telegram 账号
- Supabase 账号 (免费 tier 够用)
- Vercel 账号 (免费 tier 够用)
- GitHub 仓库

---

## Step 1: 创建 Supabase 项目

### 1.1 创建项目

1. 访问 https://supabase.com/dashboard
2. New Project → 选区域 (推荐 Southeast Asia 或离你最近的)
3. 记录以下信息:
   - **Project URL**: `https://xxxxx.supabase.co`
   - **Anon Key**: `eyJ...` (公开的，可以放前端)
   - **Service Role Key**: `eyJ...` (机密！只用于 Edge Functions)

### 1.2 执行数据库迁移

```bash
# 安装 Supabase CLI
npm install -g supabase

# 登录
supabase login

# 链接到你的项目
supabase link --project-ref YOUR_PROJECT_REF

# 按顺序执行所有 18 个迁移
supabase db push
```

如果 `db push` 失败，可以手动在 Supabase Dashboard → SQL Editor 中逐个执行:
```
001_phase1_schema.sql
002_trade_rpc_functions.sql
...
018_production_hardening.sql
```

### 1.3 部署 Edge Functions

```bash
# 一次性部署所有 Edge Functions
supabase functions deploy close-trade
supabase functions deploy execute-trade
supabase functions deploy market-oracle
supabase functions deploy scan-liquidations
supabase functions deploy openclaw-trade
supabase functions deploy openclaw-conservative
supabase functions deploy openclaw-chaos
supabase functions deploy join-tournament
supabase functions deploy settle-tournament
supabase functions deploy generate-api-key
supabase functions deploy claim-daily-reward
supabase functions deploy get-trade-history
supabase functions deploy get-achievements
supabase functions deploy check-achievements
supabase functions deploy send-notifications
supabase functions deploy process-outbox
supabase functions deploy get-referral
supabase functions deploy register-referral
supabase functions deploy manage-price-alerts
supabase functions deploy cleanup-logs
```

或者用脚本一键部署:
```bash
for fn in supabase/functions/*/index.ts; do
  name=$(basename $(dirname "$fn"))
  [ "$name" = "_shared" ] && continue
  echo "Deploying $name..."
  supabase functions deploy "$name"
done
```

### 1.4 配置 Supabase Secrets

```bash
# Telegram Bot Token (Step 2 获取后设置)
supabase secrets set TELEGRAM_BOT_TOKEN=YOUR_BOT_TOKEN

# Internal secret for generate-api-key
supabase secrets set INTERNAL_SECRET=$(openssl rand -hex 32)
```

### 1.5 配置 Cron Jobs

在 Supabase Dashboard → Database → Extensions → 启用 `pg_cron`

然后在 SQL Editor 执行:

```sql
-- 清算扫描 (每 60 秒)
SELECT cron.schedule('scan-liquidations', '* * * * *',
  $$SELECT net.http_post(
    url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/scan-liquidations',
    headers := '{"Authorization": "Bearer YOUR_SERVICE_ROLE_KEY"}'::jsonb
  )$$
);

-- OpenClaw AI Agent (每 10 分钟)
SELECT cron.schedule('openclaw-trade', '*/10 * * * *',
  $$SELECT net.http_post(
    url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/openclaw-trade',
    headers := '{"Authorization": "Bearer YOUR_SERVICE_ROLE_KEY"}'::jsonb
  )$$
);

-- OpenClaw Conservative (每 15 分钟)
SELECT cron.schedule('openclaw-conservative', '*/15 * * * *',
  $$SELECT net.http_post(
    url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/openclaw-conservative',
    headers := '{"Authorization": "Bearer YOUR_SERVICE_ROLE_KEY"}'::jsonb
  )$$
);

-- OpenClaw Chaos (每 20 分钟)
SELECT cron.schedule('openclaw-chaos', '*/20 * * * *',
  $$SELECT net.http_post(
    url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/openclaw-chaos',
    headers := '{"Authorization": "Bearer YOUR_SERVICE_ROLE_KEY"}'::jsonb
  )$$
);

-- 通知发送 (每 5 分钟)
SELECT cron.schedule('send-notifications', '*/5 * * * *',
  $$SELECT net.http_post(
    url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/send-notifications',
    headers := '{"Authorization": "Bearer YOUR_SERVICE_ROLE_KEY"}'::jsonb
  )$$
);

-- Outbox 处理器 (每 30 秒 — pg_cron 最小粒度 1 分钟，用两条错开)
SELECT cron.schedule('process-outbox-a', '* * * * *',
  $$SELECT net.http_post(
    url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/process-outbox',
    headers := '{"Authorization": "Bearer YOUR_SERVICE_ROLE_KEY"}'::jsonb
  )$$
);

-- 锦标赛结算 (每 5 分钟)
SELECT cron.schedule('settle-tournament', '*/5 * * * *',
  $$SELECT net.http_post(
    url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/settle-tournament',
    headers := '{"Authorization": "Bearer YOUR_SERVICE_ROLE_KEY"}'::jsonb
  )$$
);

-- 日志清理 (每天凌晨 3:00 UTC)
SELECT cron.schedule('cleanup-logs', '0 3 * * *',
  $$SELECT net.http_post(
    url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/cleanup-logs',
    headers := '{"Authorization": "Bearer YOUR_SERVICE_ROLE_KEY"}'::jsonb
  )$$
);
```

---

## Step 2: 创建 Telegram Bot

### 2.1 注册 Bot

1. 打开 Telegram，搜索 `@BotFather`
2. 发送 `/newbot`
3. 设置 Bot 名称: `OpenClaw Arena` (或你想要的名字)
4. 设置 Bot 用户名: `OpenClawArenaBot` (必须以 Bot 结尾)
5. **保存 Bot Token** — 格式: `123456789:ABCdefGHIjklMNOpqrSTUvwxYZ`

### 2.2 配置 Web App

继续和 BotFather 对话:

```
/mybots → 选择你的 bot → Bot Settings → Menu Button
→ Configure menu button
→ 输入 URL: https://your-vercel-app.vercel.app
→ 输入按钮文字: Open Arena
```

或者用命令:
```
/setmenubutton
→ 选择 bot
→ 输入 Web App URL
```

### 2.3 设置 Bot 描述

```
/setdescription
→ Crypto trading arena. Humans vs The Lobster. Trade BTC/ETH with up to 100x leverage.

/setabouttext
→ OpenClaw Arena - TG Trading Simulator

/setuserpic
→ 上传一个龙虾 🦞 头像
```

### 2.4 回到 Supabase 设置 Token

```bash
supabase secrets set TELEGRAM_BOT_TOKEN=123456789:ABCdefGHIjklMNOpqrSTUvwxYZ
```

---

## Step 3: 部署 Next.js 到 Vercel

### 3.1 推送代码到 GitHub

```bash
cd "/Users/z/Desktop/OpenClaw Arena"
git init
git add -A
git commit -m "feat: OpenClaw Arena full release (Phases 1-4)"
git remote add origin https://github.com/YOUR_USERNAME/openclaw-arena.git
git push -u origin main
```

**重要**: 确保 `.env.local` 在 `.gitignore` 中！

### 3.2 在 Vercel 部署

1. 访问 https://vercel.com/new
2. Import 你的 GitHub 仓库
3. Framework: Next.js (自动检测)
4. 设置环境变量:

| Variable | Value |
|----------|-------|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://xxxxx.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | `eyJ...your-anon-key` |
| `NEXT_PUBLIC_DEV_MODE` | `false` |

5. Deploy!

### 3.3 获取部署 URL

部署完成后，你会得到一个 URL:
```
https://openclaw-arena.vercel.app
```

### 3.4 回到 BotFather 更新 Web App URL

```
/mybots → 选择 bot → Bot Settings → Menu Button → Configure
→ URL: https://openclaw-arena.vercel.app
```

---

## Step 4: 配置 Supabase Auth (TG 登录)

### 4.1 启用匿名认证

Supabase Dashboard → Authentication → Providers → 启用 Anonymous Sign-in

这是因为 TG Web App 使用的是 `initDataUnsafe` 作为身份来源，真正的认证在 Edge Function 的 `getUserFromAuth()` 中处理。

### 4.2 配置 Auth URL

Supabase Dashboard → Authentication → URL Configuration:
- Site URL: `https://openclaw-arena.vercel.app`
- Redirect URLs: `https://openclaw-arena.vercel.app/**`

---

## Step 5: 验证部署

### 5.1 浏览器测试 (Dev Mode)

访问 `https://openclaw-arena.vercel.app`，如果 `NEXT_PUBLIC_DEV_MODE=false`，你会看到空白 (因为不在 TG 里)。

临时设为 `true` 测试 UI，确认后改回 `false`。

### 5.2 Telegram 测试

1. 在 Telegram 中搜索你的 Bot
2. 点击 "Start" 或底部的 "Open Arena" 按钮
3. Web App 应该在 TG 内打开

### 5.3 功能验证清单

```
[ ] Web App 在 TG 中正常打开
[ ] 价格实时更新 (Binance WebSocket)
[ ] 可以开仓 (Long/Short)
[ ] 可以平仓
[ ] 排行榜加载
[ ] OpenClaw Widget 显示 AI 状态
[ ] 战报海报生成
[ ] 每日签到奖励
[ ] 锦标赛页面加载
[ ] 交易历史页面
[ ] 成就页面
[ ] 推荐页面 (生成邀请链接)
[ ] 价格预警设置
```

### 5.4 Cron Job 验证

在 Supabase Dashboard → Logs → Edge Functions，检查:
```
[ ] scan-liquidations 每分钟执行
[ ] openclaw-trade 每 10 分钟执行
[ ] send-notifications 每 5 分钟执行
[ ] process-outbox 每分钟执行
```

---

## Step 6: 创建首个锦标赛

在 Supabase SQL Editor 中:

```sql
INSERT INTO public.tournaments (name, description, start_at, end_at, max_participants, min_balance)
VALUES (
  'The Lobster''s Debut',
  'First ever OpenClaw Arena tournament! 72 hours of trading.',
  NOW() + INTERVAL '1 hour',
  NOW() + INTERVAL '73 hours',
  100,
  100
);
```

---

## 环境变量完整清单

### Next.js (Vercel)

| Variable | Required | Description |
|----------|----------|-------------|
| `NEXT_PUBLIC_SUPABASE_URL` | Yes | Supabase 项目 URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Yes | Supabase 公开 Key |
| `NEXT_PUBLIC_DEV_MODE` | No | `false` for production |

### Supabase Secrets (Edge Functions)

| Secret | Required | Description |
|--------|----------|-------------|
| `SUPABASE_URL` | Auto | 自动注入 |
| `SUPABASE_SERVICE_ROLE_KEY` | Auto | 自动注入 |
| `TELEGRAM_BOT_TOKEN` | Yes | BotFather 获取 |
| `INTERNAL_SECRET` | Yes | `openssl rand -hex 32` 生成 |

---

## 常见问题

### Q: Web App 打开白屏?
- 检查 Vercel 部署是否成功
- 检查 `NEXT_PUBLIC_SUPABASE_URL` 是否正确
- 查看浏览器 Console 报错

### Q: 交易报错 401?
- 确认 Supabase Auth 已启用匿名认证
- 确认 `x-user-id` header 在 CORS 允许列表中

### Q: AI Agent 没有交易?
- 检查 `openclaw-trade` cron 是否在运行
- 检查 Binance API 是否可达 (某些地区需要代理)
- 查看 Edge Function Logs

### Q: 通知没收到?
- 确认 `TELEGRAM_BOT_TOKEN` 已设置
- 确认用户已和 Bot 私聊过 (发送 /start)
- 检查 `notification_log` 表中 `delivered` 状态

### Q: Binance WebSocket 连不上?
- 中国大陆需要配置代理或使用镜像域名
- 检查 `lib/binance-ws.ts` 中的 WebSocket URL
