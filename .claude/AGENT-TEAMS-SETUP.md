# Agent Teams 設定指南

> **QuitFood Project**: Claude Code Agent Teams 配置說明

---

## 啟用 Agent Teams

### 1. 設定環境變數

在終端機中設定：

```bash
# macOS/Linux
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

# 或加入 ~/.zshrc / ~/.bashrc
echo 'export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1' >> ~/.zshrc
source ~/.zshrc
```

### 2. 配置 settings.json

已在 `.claude/settings.json` 中配置：

```json
{
  "agentTeams": {
    "enabled": true,
    "defaultModel": "sonnet",
    "displayMode": "split",
    "maxTeammates": 4,
    "delegationMode": false
  }
}
```

### 3. 顯示模式選擇

| 模式 | 說明 | 適用情境 |
|------|------|---------|
| `in-process` | 單一終端內顯示 | 一般開發 |
| `split` | 分割視窗（需 tmux/iTerm2） | 複雜協作 |

若要使用 split 模式：
- **tmux**: 需要 tmux 3.0+
- **iTerm2**: 需要 iTerm2 3.0+

---

## 使用方式

### 啟動團隊指令

```bash
# 在 Claude Code 中執行

# 啟動產品組
/spawn-product-team

# 啟動開發組
/spawn-dev-team

# 啟動測試組
/spawn-test-team

# 啟動完整團隊（端對端）
/spawn-full-team
```

### 手動啟動 Teammate

在 Claude Code 對話中使用：

```
spawn teammate named "Code Architect" with prompt:
你是 QuitFood 專案的程式架構師。請設計 [功能名稱] 的 Clean Architecture 架構。
請遵守 @rules/tech-stack.md 和 @rules/coding-style.md。
```

### 團隊間溝通

Teammates 可以互相發送訊息：

```
# Teammate A (Code Architect) 發送給 Backend Developer
send message to "Backend Developer":
Schema 設計已完成，請開始實作 Edge Functions。
quit_journeys 表結構見 migrations/001_create_tables.sql
```

---

## 團隊結構

```
┌─────────────────────────────────────────────────────────────┐
│                    Team Lead (你 / Coordinator)              │
│                         協調所有團隊                          │
└─────────────────────────────────────────────────────────────┘
                               │
       ┌───────────────────────┼───────────────────────┐
       ▼                       ▼                       ▼
┌─────────────┐       ┌─────────────┐       ┌─────────────┐
│ Product Team│       │  Dev Team   │       │ Test Team   │
├─────────────┤       ├─────────────┤       ├─────────────┤
│ BA          │       │ Architect   │       │ Generator   │
│ Designer    │       │ DB Architect│       │ Engineer    │
│ Strategist  │       │ Backend Dev │       │ Runner      │
│             │       │ Mobile Dev  │       │             │
└─────────────┘       └─────────────┘       └─────────────┘
       │                       │                       │
       └───────────────────────┼───────────────────────┘
                               ▼
                        Tech Lead Review
```

---

## Shared Task List

所有 teammates 共享同一個任務列表，用於：

1. **追蹤進度**: 每個 teammate 標記自己的任務完成
2. **依賴管理**: 確保任務按正確順序執行
3. **協調溝通**: 了解其他 teammate 的狀態

範例任務列表：

```
[ ] 需求分析 - Business Analyst
[ ] UI 設計 - UI/UX Designer
[ ] 架構設計 - Code Architect
[ ] Schema 設計 - Supabase Architect
[ ] Edge Functions - Backend Developer
[ ] Flutter UI - Mobile Developer
[ ] 測試設計 - Test Generator
[ ] 測試實作 - Test Engineer
[ ] 測試執行 - Test Runner
[ ] 最終審查 - Tech Lead
```

---

## Delegation Mode

如果啟用 `delegationMode: true`：

- Team Lead **只能協調**，不能直接執行任務
- 所有實際工作由 teammates 完成
- 適用於大型功能開發

```json
{
  "agentTeams": {
    "delegationMode": true
  }
}
```

---

## 最佳實踐

### 何時使用 Agent Teams

| 情境 | 建議 |
|------|------|
| 完整功能開發 | `/spawn-full-team` |
| 僅需需求分析 | `/spawn-product-team` |
| 僅需程式實作 | `/spawn-dev-team` |
| 僅需測試驗證 | `/spawn-test-team` |
| 簡單修改 | 不需要，直接編輯 |

### 團隊規模建議

- **小功能**: 2-3 teammates
- **中功能**: 4-6 teammates
- **大功能**: 使用完整團隊 + delegation mode

### 錯誤處理

如果 teammate 失敗：
1. 檢查錯誤訊息
2. 調整 prompt 重新啟動
3. 或手動完成該部分工作

---

## 檔案結構

```
.claude/
├── settings.json              # Agent Teams 配置
├── AGENT-TEAMS-SETUP.md       # 本說明文件
├── commands/                  # Slash Commands
│   ├── spawn-product-team.md
│   ├── spawn-dev-team.md
│   ├── spawn-test-team.md
│   └── spawn-full-team.md
├── agents/                    # Agent 定義
│   ├── ALL-TEAM.md
│   ├── tech-lead.md
│   └── ...
├── rules/                     # 專案規則
│   ├── tech-stack.md
│   └── ...
└── skills/                    # 領域知識
    ├── quitfood-domain/
    └── ...
```

---

## 故障排除

### Agent Teams 未啟用

```bash
# 確認環境變數
echo $CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
# 應該輸出 1
```

### Split 模式不工作

```bash
# 確認 tmux 版本
tmux -V
# 需要 3.0+

# 或使用 iTerm2 並確認已啟用 API
```

### Teammate 無法溝通

確認 teammate 名稱正確，區分大小寫。

---

## 參考資源

- [Claude Code Agent Teams 文檔](https://docs.anthropic.com/en/docs/claude-code/agent-teams)
- [QuitFood 專案 README](../README.md)
- [技術棧規範](./rules/tech-stack.md)
