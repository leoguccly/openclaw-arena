# Spawn Dev Team

啟動開發組進行架構設計與程式實作。

## 指令

當用戶要求實作功能、設計架構、建立資料庫時，使用此指令啟動開發組團隊。

## 前置條件

需要有產品組產出的 README.md 作為輸入。

## 執行流程

```
spawn-teammate: Code Architect
你是 QuitFood 專案的程式架構師。根據 README.md 設計：
1. Clean Architecture 分層結構
2. Repository Interface 定義
3. UseCase 與數據流設計
請遵守 @rules/tech-stack.md 和 @rules/coding-style.md。

---

spawn-teammate: Supabase Schema Architect
你是 QuitFood 專案的資料庫架構師。根據架構設計，產出：
1. PostgreSQL Schema (Migration SQL)
2. RLS Policy（每表都要）
3. 索引策略
請遵守 @rules/security.md 的 RLS 規範和 @skills/supabase-postgres-best-practices。

---

spawn-teammate: Backend Developer
你是 QuitFood 專案的後端開發者。根據 Schema 設計，實作：
1. Supabase Edge Functions (Deno/TypeScript)
2. 第三方 API 整合
3. 所有 API Keys 透過 Supabase Secrets
請遵守 @rules/security.md 的 API 安全規範。

---

spawn-teammate: Mobile Developer
你是 QuitFood 專案的行動開發者。根據 API 設計，實作：
1. Flutter UI (Riverpod 狀態管理)
2. 離線優先架構
3. 本地通知整合
請遵守 @rules/tech-stack.md 和 @rules/coding-style.md。
```

## 團隊協作規則

- 架構師先完成，其他人依序接力
- 使用 shared task list 追蹤每個檔案的進度
- Schema Architect 與 Backend Developer 可平行工作
- Mobile Developer 等待 Backend API 定義完成

## 完成標準

- [ ] `flutter analyze` 無錯誤
- [ ] 零 `dynamic` 類型
- [ ] Clean Architecture 分層正確
- [ ] RLS 政策完整
- [ ] 離線支援正確實作
