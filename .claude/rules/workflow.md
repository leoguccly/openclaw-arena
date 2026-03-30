# Workflow 工作流程規範

> **強制性**: 本文件定義的流程為專案憲法，不可違背。

## Single Source of Truth (SSOT) 原則

### 資料來源優先級

```
1. Supabase PostgreSQL (唯一真相來源)
   ↓ 同步
2. 本地儲存 (Hive/Drift) - 離線快取
   ↓ 衍生
3. UI 狀態 (Riverpod) - 展示用
```

### 資料流向

```
[Supabase] ←→ [Repository] ←→ [UseCase] ←→ [Provider] → [UI]
     ↑              ↓
     └── [LocalDataSource] ←── 離線快取
```

## Git 工作流程

### 分支策略

```
main (生產)
  │
  ├── develop (開發整合)
  │     │
  │     ├── feature/journey-tracking
  │     ├── feature/craving-record
  │     └── fix/quit-days-calculation
  │
  └── release/v1.0.0 (發布準備)
```

### 分支命名

```
feature/  - 新功能
fix/      - 修復 bug
refactor/ - 重構
docs/     - 文檔
test/     - 測試
chore/    - 建置/設定
```

### Commit 規範

```
<type>(<scope>): <subject>

Types:
- feat:     新功能
- fix:      修復
- docs:     文檔
- style:    格式
- refactor: 重構
- test:     測試
- chore:    雜項

Examples:
feat(journey): 新增戒食旅程功能
fix(checkin): 修正打卡日期計算錯誤
docs(readme): 更新安裝說明
```

### Pull Request 流程

```
1. 從 develop 建立 feature 分支
2. 開發並提交
3. 確保通過：
   - flutter analyze
   - flutter test
   - dart format --set-exit-if-changed .
4. 建立 PR 到 develop
5. Code Review (至少 1 人)
6. Squash and Merge
```

## 開發流程

### 功能開發流程

```
1. 需求分析 (產品組)
   └── 輸出：README.md (User Stories, Edge Cases)

2. 架構設計 (開發組 - Code Architect)
   └── 輸出：架構設計文檔

3. 資料庫設計 (開發組 - Supabase Architect)
   └── 輸出：Migration SQL, RLS Policy

4. 後端實作 (開發組 - Backend Developer)
   └── 輸出：Edge Functions

5. 前端實作 (開發組 - Mobile Developer)
   └── 輸出：Flutter Code

6. 測試 (測試組)
   └── 輸出：測試報告

7. 代碼審查 (Tech Lead)
   └── 輸出：審查通過 / 修改建議
```

### 開發順序

```
1. Domain Layer
   ├── Entity
   └── Repository Interface

2. Data Layer
   ├── Model (DTO)
   ├── DataSource (Local + Remote)
   └── Repository Implementation

3. Presentation Layer
   ├── Provider
   ├── Widget
   └── Page

4. Test
   ├── Unit Tests
   ├── Widget Tests
   └── Integration Tests
```

## 檔案組織

### 功能目錄結構

```
lib/
├── features/
│   └── journey/           # 功能模組
│       ├── domain/
│       │   ├── entities/
│       │   │   └── quit_journey.dart
│       │   ├── repositories/
│       │   │   └── journey_repository.dart
│       │   └── usecases/
│       │       └── start_journey.dart
│       ├── data/
│       │   ├── models/
│       │   │   └── journey_model.dart
│       │   ├── datasources/
│       │   │   ├── journey_local_datasource.dart
│       │   │   └── journey_remote_datasource.dart
│       │   └── repositories/
│       │       └── journey_repository_impl.dart
│       └── presentation/
│           ├── pages/
│           │   └── journey_page.dart
│           ├── widgets/
│           │   └── quit_day_counter.dart
│           └── providers/
│               └── journey_provider.dart
```

## CI/CD 流程

### PR 檢查 (必須全部通過)

```yaml
# .github/workflows/pr-check.yml
name: PR Check

on:
  pull_request:
    branches: [main, develop]

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.x'

      - name: Install dependencies
        run: flutter pub get

      - name: Analyze
        run: flutter analyze --fatal-infos

      - name: Format check
        run: dart format --set-exit-if-changed .

      - name: Test
        run: flutter test --coverage

      - name: Coverage check
        run: |
          COVERAGE=$(lcov --summary coverage/lcov.info 2>&1 | grep "lines" | awk '{print $2}' | tr -d '%')
          if (( $(echo "$COVERAGE < 80" | bc -l) )); then
            echo "Coverage $COVERAGE% is below 80%"
            exit 1
          fi
```

### 發布流程

```
1. 從 develop 建立 release/vX.X.X 分支
2. 更新版本號 (pubspec.yaml)
3. 更新 CHANGELOG.md
4. 測試完整流程
5. Merge 到 main
6. 建立 Git Tag
7. 觸發自動部署
```

## 協作規範

### 團隊調用

```
# 完整功能開發
請依序啟動產品組、開發組、測試組來開發 [功能名稱]

# 單一角色
請 @code-architect 設計 [功能] 的架構
請 @supabase-schema-architect 設計 [功能] 的資料表
請 @mobile-developer 實作 [頁面]
請 @test-generator 產出 [功能] 的測試規範
請 @tech-lead 審查這段程式碼
```

### 交付物檢查

```
產品組交付:
- [ ] README.md (User Stories, Edge Cases, UI Tasks)

開發組交付:
- [ ] 架構設計文檔
- [ ] Migration SQL
- [ ] Edge Functions
- [ ] Flutter Code
- [ ] flutter analyze 無錯誤

測試組交付:
- [ ] test_task.md
- [ ] 測試程式碼
- [ ] 覆蓋率 > 80%
- [ ] flutter test 全部通過

Tech Lead 交付:
- [ ] 代碼審查報告
- [ ] 品味評分 (🟢/🟡/🔴)
```

## 文檔規範

### 必要文檔

```
docs/
├── README.md           # 專案總覽
├── ARCHITECTURE.md     # 架構說明
├── SETUP.md           # 開發環境設定
├── DEPLOYMENT.md      # 部署流程
└── features/
    └── [feature].md   # 功能規格
```

### README.md 模板

```markdown
# 功能名稱

## 概述
[功能描述]

## User Stories
- As a [角色], I want [功能], so that [價值]

## Edge Cases
- EC-1: [邊界情況]

## UI Tasks
- [ ] Task 1 - [驗收標準]

## 成功指標
- [指標定義]
```

## 版本管理

### 語意化版本

```
MAJOR.MINOR.PATCH

MAJOR: 不相容的 API 變更
MINOR: 向後相容的新功能
PATCH: 向後相容的 bug 修復

範例:
1.0.0 - 首次發布
1.1.0 - 新增渴望記錄功能
1.1.1 - 修正打卡日期 bug
2.0.0 - 重大架構調整
```

### CHANGELOG 格式

```markdown
# Changelog

## [1.1.0] - 2024-01-15

### Added
- 新增渴望記錄功能
- 新增統計圖表

### Fixed
- 修正跨時區打卡問題

### Changed
- 改善首頁載入速度
```
