# Tech Stack 技術棧規範

> **強制性**: 本文件定義的技術選型為專案憲法，不可違背。

## 前端技術棧

### Flutter
- **版本**: Flutter 3.x (Dart 3.x)
- **最低支援**: iOS 12.0 / Android API 24

### 狀態管理
- **主要**: Riverpod 2.x (使用 riverpod_generator)
- **禁止**: setState、Provider (舊版)、GetX、Bloc

### 路由
- **主要**: go_router
- **禁止**: Navigator 1.0 直接使用

### 本地儲存
- **結構化資料**: Hive 或 Drift
- **簡單 KV**: shared_preferences
- **禁止**: SQLite 直接使用（用 Drift 封裝）

### 網路
- **HTTP**: Supabase Client（不直接用 dio/http）
- **即時**: Supabase Realtime

### UI 元件
- **主要**: Material 3
- **圖示**: Material Icons + cupertino_icons
- **字體**: Google Fonts (Noto Sans TC, Space Grotesk)

## 後端技術棧

### Supabase
- **資料庫**: PostgreSQL 15+
- **認證**: Supabase Auth
- **儲存**: Supabase Storage
- **函數**: Supabase Edge Functions (Deno)
- **即時**: Supabase Realtime

### Edge Functions
- **Runtime**: Deno
- **語言**: TypeScript (strict)
- **禁止**: Node.js 語法、CommonJS

## 架構模式

### Clean Architecture (強制)
```
lib/
├── core/           # 工具、常數
├── domain/         # Entity、Repository 介面、UseCase
├── data/           # Model、DataSource、Repository 實作
└── presentation/   # Page、Widget、Provider
```

### 依賴規則
```
Presentation → Domain ← Data
       ↓          ↑        ↓
   (依賴)     (反向依賴)  (依賴)
```

- ✅ Presentation 可依賴 Domain
- ✅ Data 可依賴 Domain
- ❌ Domain 不可依賴 Data 或 Presentation

## 禁止事項

### Flutter 禁止清單
```dart
// ❌ 禁止 dynamic
dynamic data;

// ❌ 禁止 setState（Riverpod 專案）
setState(() {});

// ❌ 禁止 ignore 註解
// ignore: ...

// ❌ 禁止缺少 const
Widget build() => MyWidget();  // 應該是 const MyWidget()

// ❌ 禁止 print（用 debugPrint）
print('debug');
```

### Supabase 禁止清單
```sql
-- ❌ 禁止無 RLS 的表
CREATE TABLE xxx (...);  -- 缺少 ENABLE ROW LEVEL SECURITY

-- ❌ 禁止 SELECT *
SELECT * FROM journeys;  -- 應明確指定欄位

-- ❌ 禁止無索引的常用查詢欄位
-- 對於 WHERE 常用的欄位必須建立索引
```

### API 禁止清單
```typescript
// ❌ 禁止前端直接呼叫第三方 API
// 所有第三方服務必須透過 Edge Functions

// ❌ 禁止 API Key 暴露在前端
const API_KEY = 'xxx';  // 永遠不要這樣做
```

## 版本鎖定

```yaml
# pubspec.yaml 版本規範
environment:
  sdk: '>=3.0.0 <4.0.0'
  flutter: '>=3.10.0'

dependencies:
  flutter_riverpod: ^2.4.0
  riverpod_annotation: ^2.3.0
  go_router: ^12.0.0
  supabase_flutter: ^2.0.0
  hive_flutter: ^1.1.0
  google_fonts: ^6.0.0
  fpdart: ^1.1.0  # Either<Failure, T>

dev_dependencies:
  riverpod_generator: ^2.3.0
  build_runner: ^2.4.0
  flutter_test:
    sdk: flutter
  mocktail: ^1.0.0
```

## 環境變數

### 本地開發 (.env.local)
```
SUPABASE_URL=
SUPABASE_ANON_KEY=
```

### 生產環境
- 使用 Supabase Secrets 管理
- 禁止將 secrets 提交到 Git

## 遵守檢查

每次 PR 必須通過：
```bash
# 靜態分析
flutter analyze --fatal-infos

# 測試
flutter test

# 格式化
dart format --set-exit-if-changed .
```
