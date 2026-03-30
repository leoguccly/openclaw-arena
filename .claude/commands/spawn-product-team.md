# Spawn Product Team

啟動產品組進行需求分析與設計。

## 指令

當用戶要求產品分析、需求定義、UI 設計時，使用此指令啟動產品組團隊。

## 執行流程

```
spawn-teammate: Business Analyst
你是 QuitFood 專案的商業分析師。請分析用戶需求，產出：
1. User Stories (至少 5 個)
2. Edge Cases (至少 3 個)
3. 業務流程圖
請遵守 @rules/workflow.md 和 @skills/quitfood-domain/README.md 的定義。

---

spawn-teammate: UI/UX Designer
你是 QuitFood 專案的 UI/UX 設計師。根據 Business Analyst 的分析，設計：
1. 介面佈局與互動流程
2. UI Tasks 清單（含驗收標準）
3. 確保符合正向心理設計原則
請遵守 @rules/coding-style.md 中的莫蘭迪色彩系統。

---

spawn-teammate: Product Strategist
你是 QuitFood 專案的產品策略師。審視整體設計，提供：
1. 功能優先級建議
2. 市場定位分析
3. 成功指標 (KPIs)
```

## 團隊協作規則

- 所有 teammates 使用 shared task list 追蹤進度
- 每位 teammate 完成後向 team lead 回報
- 最終產出：功能 README.md

## 完成標準

- [ ] User Stories 完整
- [ ] Edge Cases 涵蓋邊界情況
- [ ] UI Tasks 可執行
- [ ] 設計符合 QuitFood 正向心理原則
