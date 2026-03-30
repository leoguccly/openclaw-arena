# OpenClaw Arena — Manual Smoke Test Checklist

> **For**: Product Owner 手动验收
> **Environment**: Telegram iOS/Android App → Web App
> **Date**: 2026-03-15
> **Prerequisites**:
> - Supabase 已部署 (`001_phase1_schema.sql` + `002_trade_rpc_functions.sql`)
> - Edge Functions 已部署 (`market-oracle`, `execute-trade`, `close-trade`)
> - Next.js 前端已部署并绑定为 TG Web App
> - `.env` 中 `NEXT_PUBLIC_SUPABASE_URL` 和 `NEXT_PUBLIC_SUPABASE_ANON_KEY` 已配置

---

## TC-1: TG 静默登录 + 初始资金发放

### 操作说明

1. 在 Telegram 中打开 OpenClaw Arena Bot
2. 点击 "Open App" 进入 Web App
3. 观察页面加载过程

### 预期结果

| 检查项 | 预期 |
|--------|------|
| 页面全屏展开 | Web App 自动展开至全屏（非半屏弹窗） |
| Header 显示用户名 | "Welcome, {你的 TG first_name}" |
| Balance 显示 | `$10,000.00`（初始资金，由 `handle_new_user()` trigger 自动写入） |
| ROI 显示 | `+0.00%`（初始状态） |
| 底部按钮可见 | LONG ↑ / SHORT ↓ 按钮**不被**底部安全区遮挡（iOS 重点验证 home indicator 区域） |
| 暗色主题 | TG header bar 为深黑色（#0A0A0B），非默认蓝/白 |

### 失败排查

- 如果 Balance 显示为 0 或页面空白 → 检查 Supabase Auth 是否正确配置 TG OAuth，以及 `handle_new_user()` trigger 是否已部署
- 如果底部被遮挡 → 检查 `layout.tsx` 中 `viewportFit: "cover"` 和 `globals.css` 中 `env(safe-area-inset-bottom)` 是否生效

---

## TC-2: 实时看盘 + 100 倍杠杆开仓

### 操作说明

1. 在主面板确认 BTC 按钮被选中（绿色边框高亮）
2. 观察价格数字（应每 3 秒刷新）
3. 点击 **LONG ↑** 按钮（变为绿色实心，SHORT 变为灰色边框）
4. 将杠杆拉杆拖到最右端（**100x**）
5. 在 Margin 输入框输入 `100`
6. 点击底部绿色 **LONG BTC @ $xxx** 按钮

### 预期结果

| 检查项 | 预期 |
|--------|------|
| 价格实时刷新 | 每 3 秒数字变化一次，金额与 Binance 现货 BTC/USDT 一致（允许 ≤2 秒延迟） |
| 杠杆显示 | 拉到最右显示 `100x`，字体为绿色 |
| 按钮文案 | 显示当前实时价格，如 `LONG BTC @ $67,432.15` |
| 点击后状态 | 按钮变为 "Executing..." 并短暂不可点击 |
| 成功后 UI 切换 | 交易控制面板**消失**，替换为**持仓卡片**，显示：`LONG 100x` 标签 + `BTC/USDT` + Entry 价格 + Liquidation 价格 + 实时浮动 PnL |
| Balance 扣减 | 从 `$10,000.00` 变为 `$9,900.00`（扣除 100 USDT margin） |
| 浮动 PnL | 实时跳动，正值显示绿色 + 绿色发光，负值显示橙色 + 橙色发光 |
| Haptic 反馈 | 手机震动一次（iOS/Android 均应触发） |

### 失败排查

- "Insufficient balance" → 检查 DB 中 users.balance 是否为 10000
- "Price feed unavailable" → `market-oracle` 未部署或 Binance API 不可达
- "You already have an open BTC/USDT position" → 数据库中已有 open 仓位，先手动清理

---

## TC-3: 平仓结算 + 核弹战报自动生成

### 操作说明

1. 确认持仓卡片正在显示实时浮动 PnL
2. 等待 10-30 秒让价格变动（产生正或负 PnL）
3. 点击绿色/橙色 **Close Position (+xx.xx)** 按钮
4. 等待平仓完成

### 预期结果

| 检查项 | 预期 |
|--------|------|
| 按钮状态 | 变为 "Closing..." 并短暂不可点击 |
| 平仓成功 | 持仓卡片消失，回到交易控制面板 |
| Balance 更新 | `$9,900.00 + settlement`（margin + 实现盈亏，但不低于 $9,900） |
| ROI 更新 | 从 `+0.00%` 变为反映新余额的值 |
| **战报自动弹出** | 全屏黑色遮罩 + 加载动画 🦞 → 0.5-2 秒后显示生成好的海报 PNG |
| 海报内容验证 | 海报上的 ROI 数字 = 持仓卡片关闭前的浮动 PnL 百分比（允许 ±0.5% 误差，因价格在平仓瞬间可能微变） |
| 海报清晰度 | 长按图片保存 → 打开相册查看 → 文字锐利无模糊（Retina 验证） |
| 海报布局 | 顶部 🦞 OPENCLAW ARENA / TG BATTLE → 中间巨型 ROI% → 嘲讽文案 → 底部 @OpenClawBot + 引流文案 |
| Share 按钮 | 点击 "Share Battle Report" → 调起系统分享面板 → 可发送至 TG 聊天/朋友圈 |

### 失败排查

- 海报模糊 → 检查 `html2canvas` 的 `scale` 参数是否为 `window.devicePixelRatio`
- 海报空白 → 检查 off-screen DOM (`left: -9999px`) 是否被 CSS 错误影响为 `display: none`

---

## TC-4: 排行榜安全性验证

### 操作说明

1. 从主面板点击右上角 **Leaderboard** 按钮
2. 查看排行榜列表
3. 打开浏览器开发者工具（或使用 TG Web App 的 debug 模式）
4. 在 Console 中执行以下攻击模拟：

```javascript
// 尝试直接查询 users 表获取 tg_id
const { data } = await supabase.from('users').select('tg_id, balance').order('roi', { ascending: false }).limit(1);
console.log('Attack result:', data);
```

```javascript
// 尝试通过 leaderboard_view 获取 tg_id
const { data, error } = await supabase.from('leaderboard_view').select('tg_id');
console.log('View attack:', data, error);
```

### 预期结果

| 检查项 | 预期 |
|--------|------|
| 排行榜正常加载 | 显示所有用户，按 ROI 降序 |
| 种族标识正确 | 人类旁显示 👤，AI agent 旁显示 🦞 |
| Top 3 发光效果 | 前三名有 neon glow 边框 |
| **攻击1: users 表直接查询** | `data` 仅返回**你自己**这一行（RLS `auth.uid() = id`），**看不到**其他用户的 tg_id |
| **攻击2: leaderboard_view 查 tg_id** | `error` 报 "column tg_id does not exist"，`data` 为 null |
| 前端不泄露 UUID | 排行榜 HTML/Network 请求中不包含任何 `id` 或 `tg_id` 字段 |

### 失败排查

- 如果攻击1返回多行 → `USING(TRUE)` 旧策略未删除，RLS 有漏洞，**立即停止上线**
- 如果 leaderboard_view 返回 tg_id → VIEW 定义有误，**立即修复 migration**

---

## TC-5: 网络异常 — 平仓超时后战报数据安全性验证

### 背景

> PO 核心质疑：如果 close-trade 请求超时，前端会不会用错误数据（如 PnL=0）生成海报？

### 操作说明

1. 开一个 100x LONG 仓位（参照 TC-2）
2. 等待产生明显浮动 PnL（正或负均可，≥ $5）
3. **模拟网络断开**：在手机上开启飞行模式（或在 TG Web App 的 DevTools Network 面板中选择 "Offline"）
4. 点击 **Close Position** 按钮
5. 观察 UI 反应
6. **恢复网络**，刷新页面，查看状态

### 预期结果

| 检查项 | 预期 |
|--------|------|
| 点击 Close 后 | 按钮显示 "Closing..." 约 5-10 秒 |
| 网络超时后 | 底部出现橙色错误条：**"Network error. Try again."** |
| **战报是否弹出** | **不弹出**。代码逻辑分析：`setShowPoster(true)` 位于 `try` 块的成功路径（`page.tsx:187`）。网络超时触发 `catch` 块（`page.tsx:191`），执行 `setError(...)` 并 `return`，`setShowPoster(true)` **永远不会执行** |
| 持仓状态保持 | 持仓卡片仍然显示，仓位未被关闭，浮动 PnL 继续跳动 |
| 恢复网络后 | 刷新页面 → 持仓卡片仍在，数据一致 |
| **不会生成错误海报** | 因为 poster 组件从未被渲染，不可能生成 PnL=0 的错误海报 |

### 边界案例：服务端已平仓但响应超时

| 检查项 | 预期 |
|--------|------|
| 场景 | Edge Function 成功执行了 `close_trade_txn`（DB 已更新），但 HTTP 响应在返回途中超时 |
| 前端表现 | 显示 "Network error"，持仓卡片仍显示旧仓位 |
| 刷新页面后 | 持仓卡片**消失**（因为 DB 中 status 已变为 'closed'），Balance 已更新为结算后金额 |
| 战报风险 | **无风险** — 刷新后没有 openTrade，不会触发平仓流程，也不会自动弹出海报。用户可以在主面板手动点击 📸 按钮查看最近一笔交易的战报（使用 `lastClosedTrade` 状态） |
| 手动验证方法 | 恢复网络后在 Supabase Dashboard → Table Editor → trades 表中确认该仓位 status = 'closed' 且 realised_pnl 已正确计算 |

---

## 验收签字区

| TC | 结果 | 签字 | 日期 |
|----|------|------|------|
| TC-1 TG 登录 + 初始资金 | ☐ Pass / ☐ Fail | | |
| TC-2 看盘 + 100x 开仓 | ☐ Pass / ☐ Fail | | |
| TC-3 平仓 + 核弹战报 | ☐ Pass / ☐ Fail | | |
| TC-4 排行榜安全验证 | ☐ Pass / ☐ Fail | | |
| TC-5 网络异常战报安全 | ☐ Pass / ☐ Fail | | |

> **上线标准**: 5/5 全部 Pass 方可进入生产部署。
> TC-4 如果有**任何**安全漏洞发现，**立即阻断上线流程**。
