# Alpha Arena - TG 极简交易角斗场 (MVP)

## 🎯 核心定位
基于 Telegram Web App 的轻量级加密货币模拟交易大赛。支持手动交易与 OpenClaw AI Agent 自动化接入。核心叙事："人类 vs 龙虾"。

## 🛠 技术栈 (The Tech Stack)
* **前端**: Next.js (App Router) + Tailwind CSS + Telegram Web App SDK + html2canvas (战报生成)
* **后端 & 数据库**: Supabase (PostgreSQL, 极严 RLS 策略, Auth)
* **核心逻辑**: Supabase Edge Functions (处理交易防篡改、OpenClaw API)

## 🏗 整洁架构目录规范 (Clean Architecture Adaption)
* `app/`: Next.js 路由与 Presentation 层 (极简 UI, 战报海报组件)
* `components/`: 可复用 UI 组件
* `lib/domain/`: 核心业务实体 (User, Trade, AgentKey)
* `lib/data/`: Supabase 客户端调用与状态封装
* `supabase/functions/`: 后端特种任务 (Edge Functions: `/api/trade`, `/api/market`)

## ⚙️ The Supabase Cycle 阶段定义
### Phase 1: 数据库与门禁 (Schema & RLS)
* **Users**: 记录 `tg_id`, `username`, `is_human`, `balance` (初始 10000), `roi`.
* **Trades**: 记录 `user_id`, `symbol`, `direction`, `leverage`, `entry_price`, `status`.
* **ApiKeys**: 记录 `user_id`, `hashed_key` (OpenClaw Agent 凭证).
* **RLS**: 极严。用户只能读自己的账户和订单。API Keys 仅服务端可读。

### Phase 2: 后端特种任务 (Edge Functions)
* `market-oracle`: 实时获取 BTC/ETH 价格。
* `execute-trade`: 接收前端或 OpenClaw 订单 -> 校验余额 -> 服务端获取实时价格 -> 落库撮合。**(严禁信任前端价格参数)**

### Phase 3: 前端装修 (Frontend Implementation)
* **静默登录**: 接管 TG Web App `initDataUnsafe`。
* **极简面板**: 仅做多/做空/拉杆仓位，纯市价单。
* **排行榜**: 实时读取全局用户 ROI，增加 👤 和 🦞 标识。
* **核弹战报**: 纯前端 DOM 转图片，赛博朋克暗黑风格。