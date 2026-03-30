# Spawn Full Team

啟動完整團隊進行端對端功能開發。

## 指令

當用戶要求完整開發一個功能（從需求到測試）時，使用此指令。

## 執行流程

### Phase 1: 產品組

```
spawn-teammate: Product Lead
你是產品組的組長。協調以下工作：
1. 啟動 Business Analyst 分析需求
2. 啟動 UI/UX Designer 設計介面
3. 啟動 Product Strategist 驗證策略
4. 整合產出 README.md
使用 shared task list 追蹤進度。
```

### Phase 2: 開發組

```
spawn-teammate: Dev Lead
你是開發組的組長。協調以下工作：
1. 啟動 Code Architect 設計架構
2. 啟動 Supabase Architect 設計資料庫
3. 啟動 Backend Developer 實作 API
4. 啟動 Mobile Developer 實作 UI
確保依賴順序正確，使用 shared task list。
```

### Phase 3: 測試組

```
spawn-teammate: Test Lead
你是測試組的組長。協調以下工作：
1. 啟動 Test Generator 設計測試
2. 啟動 Test Engineer 實作測試
3. 啟動 Test Runner 執行驗證
確保覆蓋率達標，失敗時協調修復。
```

### Phase 4: 最終審查

```
spawn-teammate: Tech Lead
你是 QuitFood 專案的技術領導（Linus 風格）。
請審查所有產出：
1. 代碼品質評分 (🟢/🟡/🔴)
2. 架構紅線檢查
3. 離線同步正確性
4. 數據流驗證
直接指出問題，不要委婉。
```

## 團隊協作時序

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Team Lead (Coordinator)                      │
└─────────────────────────────────────────────────────────────────────┘
     │
     ├── Phase 1: Product Team ──────────────────────────────────────▶
     │   ├── Business Analyst ──▶ Requirements
     │   ├── UI/UX Designer ──▶ Design
     │   └── Product Strategist ──▶ Strategy
     │                                    │
     │                                    ▼
     │                              README.md
     │
     ├── Phase 2: Dev Team ──────────────────────────────────────────▶
     │   ├── Code Architect ──▶ Architecture
     │   ├── Supabase Architect ──▶ Schema + RLS
     │   ├── Backend Developer ──▶ Edge Functions
     │   └── Mobile Developer ──▶ Flutter UI
     │                                    │
     │                                    ▼
     │                              Feature Code
     │
     ├── Phase 3: Test Team ─────────────────────────────────────────▶
     │   ├── Test Generator ──▶ Test Design
     │   ├── Test Engineer ──▶ Test Code
     │   └── Test Runner ──▶ Execution
     │                                    │
     │                                    ▼
     │                              Quality Report
     │
     └── Phase 4: Tech Lead Review ──────────────────────────────────▶
                                          │
                                          ▼
                                  Final Approval
```

## 完成標準

### 產品組
- [ ] README.md 完整

### 開發組
- [ ] `flutter analyze` 無錯誤
- [ ] 零 `dynamic` 類型
- [ ] RLS 完整

### 測試組
- [ ] 覆蓋率 > 80%
- [ ] 所有測試通過

### Tech Lead
- [ ] 品味評分 🟢 或 🟡
- [ ] 無架構紅線違規
