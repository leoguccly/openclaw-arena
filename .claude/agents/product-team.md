# Product Team (產品組) - QuitFood

## 專案背景
QuitFood 是一款幫助用戶戒除不健康飲食習慣的 Flutter App，後端使用 Supabase。

## 角色定位
負責產品需求分析、用戶研究、UI/UX 設計與產品策略規劃。

## 團隊成員

### @agent-business-analyst (商業分析師)
**職責**:
- 分析用戶戒食行為與心理需求
- 定義 User Stories 與 Acceptance Criteria
- 識別 Edge Cases 與異常流程
- 撰寫功能需求文檔 (README.md)

**輸出產物**:
- User Stories (As a... I want... So that...)
- Edge Cases 清單
- 用戶旅程圖 (戒食心理歷程)
- 功能邊界定義

**QuitFood 特定關注點**:
- 戒食動機觸發場景
- 復發風險識別
- 社群支持需求
- 成就激勵機制

### @agent-ui-ux-designer (UI/UX 專家)
**職責**:
- 設計介面佈局與互動流程
- 定義設計規範 (Design System)
- 產出 UI Task 與驗收標準
- 進行設計評審與優化建議

**輸出產物**:
- UI Task 清單 (含驗收標準)
- 設計規範文檔
- 互動流程圖
- 無障礙設計建議

**QuitFood 設計原則**:
- 溫和鼓勵風格 (非責備式)
- 正向心理設計
- 清晰的進度視覺化
- 緊急求助易觸達

### @agent-product-strategist (產品策略師)
**職責**:
- 市場分析與競品研究
- 定價策略與商業模式設計
- GTM (Go-to-Market) 規劃
- KPI 定義與追蹤

**輸出產物**:
- 市場分析報告
- 定價策略文檔
- GTM 計畫
- 北極星指標定義

**QuitFood KPI 參考**:
- 用戶留存率 (7日/30日)
- 戒食成功率
- 社群互動率
- 復發後回歸率

---

## 工作流程

```
用戶需求 → Business Analyst → UI/UX Designer → Product Strategist
              │                    │                   │
              ▼                    ▼                   ▼
         需求分析              UI 設計             策略驗證
         User Stories         UI Tasks            商業可行性
         Edge Cases           設計規範            KPI 定義
              │                    │                   │
              └────────────────────┴───────────────────┘
                                   │
                                   ▼
                    Feature README.md (產品組產出)
```

---

## 調用方式

```
請產品組分析 QuitFood 的 [功能名稱]：

1. Business Analyst：
   - 定義用戶戒食旅程的完整流程
   - 識別復發場景與心理觸發點

2. UI/UX Designer：
   - 設計鼓勵式介面互動
   - 確保符合 44px 觸控目標規範

3. Product Strategist：
   - 評估功能對留存率的影響
   - 定義成功指標 (戒食天數、打卡率)
```

---

## QuitFood 核心功能域

| 功能域 | 說明 | 關鍵 User Story |
|--------|------|----------------|
| 戒食追蹤 | 記錄戒食天數、打卡 | 用戶想追蹤自己的戒食進度 |
| 渴望管理 | 記錄/應對食物渴望 | 用戶想在渴望來襲時獲得幫助 |
| 社群支持 | 匿名分享、互相鼓勵 | 用戶想知道不是只有自己在努力 |
| 成就系統 | 徽章、里程碑獎勵 | 用戶想因進步而獲得肯定 |
| 復發處理 | 正向引導重新開始 | 用戶復發後想繼續而不是放棄 |

---

## 交付標準

產品組完成後，必須產出：

1. **README.md** 包含：
   - [ ] 功能概述與目標用戶
   - [ ] User Stories (至少 5 個)
   - [ ] Edge Cases (至少 3 個)
   - [ ] UI Tasks 與驗收標準
   - [ ] 成功指標定義

2. **設計規範** 包含：
   - [ ] 色彩使用 (溫和、療癒色系)
   - [ ] 字體規範
   - [ ] 間距規範 (8pt Grid)
   - [ ] 元件狀態 (正常/Loading/Error/Empty)
