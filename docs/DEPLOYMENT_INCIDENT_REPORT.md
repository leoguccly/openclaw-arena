# Alpha Arena — 部署故障排查报告

> **日期**: 2026-03-30
> **持续时间**: 约 2 小时
> **最终状态**: ✅ 全部修复，交易链路已跑通

---

## 故障链总览

```
问题1 (405) → 问题2 (405) → 问题3 (401) → 问题4 (500) → 问题5 (500) → 问题6 (500) → 问题7 (500) → ✅ 成功
```

共发现并修复 **7 个问题**，每个问题都遮盖了下一个，形成了一条"洋葱式"故障链——剥开一层才能看到下一层。

---

## 问题 1: Edge Function `serve()` 冲突 → 405

### 症状
`POST /functions/v1/execute-trade` 返回 `405 Method Not Allowed`

### 根因
`execute-trade/index.ts` 通过 `import { getServerSidePrice } from "../market-oracle/index.ts"` 导入了 `market-oracle` 的代码。`market-oracle/index.ts` 文件底部有自己的 `serve()` 调用。

**Supabase Edge Functions 的 `serve()` 是全局唯一的。** 当 Function A import 了 Function B 的 `index.ts`，B 的 `serve()` 先执行并注册了自己的 handler，A 的 `serve()` 被覆盖。`market-oracle` 只接受 GET 请求，所以 POST 返回 405。

### 修复
1. 创建 `_shared/price-feed.ts` — 只包含价格获取逻辑，**没有 `serve()` 调用**
2. 创建 `_shared/check-price-alerts.ts` — 同理，从 `manage-price-alerts` 中抽出
3. 更新所有 5 个文件的 import：`market-oracle/index.ts` → `_shared/price-feed.ts`
4. 更新 `scan-liquidations` 的 import：`manage-price-alerts/index.ts` → `_shared/check-price-alerts.ts`

### 教训
> **永远不要跨 Edge Function 互相 import `index.ts`。** 所有共享逻辑必须放在 `_shared/` 目录下（无 `serve()` 调用）。

---

## 问题 2: 函数重复定义 → 405（持续）

### 症状
重新部署后仍然 405，`deployment_id` 末尾没有变化（`_11` → `_11`）

### 根因
`execute-trade/index.ts` 同时做了两件事：
1. `import { computeLiquidationPrice, computeQuantity } from "../_shared/trade-math.ts"` — 从共享模块导入
2. 本地又定义了同名函数 `function computeLiquidationPrice(...)` 和 `function computeQuantity(...)`

**Deno 在模块加载时检测到重复定义，直接报错，`serve()` 从未注册** → 请求到达时没有 handler → 返回 405。

### 修复
删除 `execute-trade/index.ts` 中本地定义的 `computeLiquidationPrice` 和 `computeQuantity` 函数（约 30 行），只保留 shared import。

### 教训
> 重构 import 时，**必须同时删除本地的同名函数定义**。IDE 的 "导入声明与局部声明冲突" 警告是真实的编译错误，不能忽视。

---

## 问题 3: 认证 Token 为空 → 401

### 症状
函数恢复正常（405 → 401），但 `authorization: []` 为空

### 根因
`tg-auth` Edge Function 未成功返回 token，导致前端 `accessToken` 状态一直是空字符串 `""`。请求发出时 `Authorization: Bearer ` 头为空，`getUserFromAuth` 解析失败返回 null → 401。

### 修复
这不是独立问题，而是问题 4-7 的表面症状。修复 `tg-auth` 后自动解决。

---

## 问题 4: INTERNAL_SECRET 未设置 → 500（潜在）

### 症状
`tg-auth` 可能返回 500（密码包含 `undefined`）

### 根因
`tg-auth` 生成密码的代码：`password = tg_${tgId}_${Deno.env.get("INTERNAL_SECRET")}`。如果 Secret 未配置，密码变成 `tg_123_undefined`。

### 修复
1. 运行 `supabase secrets set INTERNAL_SECRET=$(openssl rand -hex 32)`
2. 在代码中增加了 INTERNAL_SECRET 存在性检查，缺失时返回明确的 500 错误信息

### 教训
> 部署 Edge Functions 前，**必须先配置所有 Supabase Secrets**。用 `supabase secrets list` 验证。

---

## 问题 5: admin.createUser 返回 Internal Server Error → 500

### 症状
`[tg-auth] createUser HTTP 500: {"code":500,"error_code":"unexpected_failure","msg":"Internal Server Error"}`

### 根因
使用 `supabase.auth.admin.createUser()` SDK 方法调用 GoTrue Admin API 时，Supabase 返回了一个不明确的 500 错误。直接用 `fetch()` 调用 REST API 也同样返回 500。

**但在 SQL Editor 里直接 INSERT into auth.users 却成功了**——说明数据库层没问题，问题在 GoTrue Auth 服务层。

### 修复
放弃 `admin.createUser()`，改用 `supabase.auth.signUp()`（用户级注册 API）。这个 API 走的是标准注册流程，更稳定。

### 教训
> **`admin.createUser()` 在某些 Supabase 配置下不稳定。** `signUp()` 是更可靠的替代方案。如果需要跳过邮件确认，在 Dashboard 关闭 "Confirm email" 选项。

---

## 问题 6: 密码超过 72 字符 → 500

### 症状
`[tg-auth] signUp result: FAILED: Password cannot be longer than 72 characters`

### 根因
密码格式：`tg_` (3) + `tgId` (10位) + `_` (1) + `INTERNAL_SECRET` (64位 hex) = **78 字符**

bcrypt 算法有硬性的 **72 字符上限**，超过的部分会被静默截断或直接拒绝。Supabase GoTrue 选择了拒绝。

### 修复
```typescript
// 之前：78 字符，超限
const password = `tg_${tgId}_${internalSecret}`;

// 之后：约 30 字符，安全范围内
const password = `tg_${tgId}_${internalSecret.slice(0, 16)}`;
```

16 个 hex 字符 = 64 bit 熵，对于内部服务账号密码已经绰绰有余。

### 教训
> 使用 bcrypt 时，**密码长度不能超过 72 字符**。如果密码包含长 secret，必须截断或哈希后再使用。

---

## 问题 7: RPC 权限被 REVOKE → 500（最后一个！）

### 症状
`[execute-trade] RPC error: { code: "42501", message: "permission denied for function execute_trade_txn" }`

### 根因
迁移文件中对所有 RPC 函数执行了：
```sql
REVOKE ALL ON FUNCTION public.execute_trade_txn FROM PUBLIC;
REVOKE ALL ON FUNCTION public.execute_trade_txn FROM anon;
REVOKE ALL ON FUNCTION public.execute_trade_txn FROM authenticated;
```

但 **只有部分 RPC 有对应的 `GRANT EXECUTE TO service_role`**（后期的迁移 008+ 有，早期的 002 没有）。Edge Functions 用 `service_role` key 创建的 Supabase 客户端调用 `.rpc()` 时，PostgreSQL 检查执行权限 → 发现 service_role 没有被显式 GRANT → 拒绝。

### 修复
在 SQL Editor 中执行全量授权：
```sql
GRANT EXECUTE ON FUNCTION public.execute_trade_txn TO service_role;
GRANT EXECUTE ON FUNCTION public.close_trade_txn TO service_role;
GRANT EXECUTE ON FUNCTION public.liquidate_trade_txn TO service_role;
-- ... 以及所有其他 RPC
```

### 教训
> **每个 `REVOKE ALL FROM PUBLIC` 都必须配一个 `GRANT EXECUTE TO service_role`。** 否则即使用 service_role key 也无法调用。早期迁移（002、003）遗漏了 GRANT 语句。

---

## 修复时间线

| 时间 (UTC) | 问题 | 状态码 | 修复 |
|-----------|------|--------|------|
| 07:19 | serve() 冲突 | 405 | 抽取 _shared/price-feed.ts |
| 07:24 | 函数重复定义 | 405 | 删除本地同名函数 |
| 07:47 | Token 为空 | 401 | (需要修 tg-auth) |
| 08:03 | admin.createUser 500 | 500 | 改用 signUp() |
| 08:07 | admin.createUser 仍 500 | 500 | 直接用 REST API |
| 08:30 | 密码超 72 字符 | 500 | slice(0, 16) |
| 08:35 | 登录成功！ | 200 | ✅ |
| 08:41 | RPC 权限拒绝 | 500 | GRANT TO service_role |
| 08:45 | **交易成功！** | **201** | ✅ **全部修复** |

---

## 预防措施（已实施或建议）

### 已实施
1. **`_shared/` 隔离规则**：所有跨函数共享的逻辑都在 `_shared/` 目录下，无 `serve()` 调用
2. **密码长度限制**：使用 `secret.slice(0, 16)` 确保不超过 bcrypt 72 字符限制
3. **详细日志**：`tg-auth` 在每个关键步骤都有 console.log，方便未来排查

### 建议
4. **部署后自动冒烟测试**：每次 `supabase functions deploy` 后，用 curl 自动测试核心路径
5. **GRANT 检查脚本**：在 CI 中检查所有 REVOKE 都有对应的 GRANT
6. **合并迁移文件同步更新**：每次修改单个迁移文件后，同步重新生成 `all_migrations_combined.sql`

---

## 架构改进总结

```
修复前：
  execute-trade → import market-oracle/index.ts (带 serve()) → 💥 冲突
  scan-liquidations → import manage-price-alerts/index.ts (带 serve()) → 💥 冲突

修复后：
  execute-trade → import _shared/price-feed.ts (无 serve()) → ✅
  scan-liquidations → import _shared/check-price-alerts.ts (无 serve()) → ✅
  market-oracle → import _shared/price-feed.ts (自己只有 serve()) → ✅
  manage-price-alerts → 自己定义 checkPriceAlerts (自己只有 serve()) → ✅
```

**新增共享模块：**
- `_shared/price-feed.ts` — Binance 价格获取 + 缓存
- `_shared/check-price-alerts.ts` — 价格预警扫描逻辑
