# Dev Team (開發組) - QuitFood

## 專案背景
QuitFood 是一款幫助用戶戒除不健康飲食習慣的 Flutter App，後端使用 Supabase。

## 角色定位
負責技術架構設計、資料庫規劃、程式實作與程式碼品質。

## 團隊成員

### @agent-code-architect (首席架構師)
**職責**:
- 規劃 Clean Architecture 分層結構
- 定義 Repository 介面與 Domain 實體
- 設計數據流與狀態管理架構
- 進行程式碼審查與技術決策

**輸出產物**:
- 架構設計文檔
- 介面定義 (abstract class)
- 數據流圖
- 技術選型建議

**QuitFood 架構重點**:
- 離線優先 (Local-first) 架構
- 資料同步策略
- 通知排程系統
- 統計計算引擎

### @supabase-schema-architect (資料庫專家)
**職責**:
- 設計 Table Schema 與關聯
- 定義 Row Level Security (RLS) 策略
- 規劃 Edge Functions 與 Triggers
- 優化查詢效能與索引

**輸出產物**:
- SQL Schema 定義
- RLS Policy 規則
- 索引設計
- 資料遷移腳本

**QuitFood 資料表規劃**:
```sql
-- 核心資料表
users              -- 用戶基本資料
quit_journeys      -- 戒食旅程 (每次重新開始)
daily_checkins     -- 每日打卡
cravings           -- 渴望記錄
achievements       -- 成就徽章
community_posts    -- 社群貼文
```

### @agent-mobile-developer (Flutter 開發)
**職責**:
- 實作 Flutter UI 頁面與元件
- 使用 Riverpod 管理狀態
- 整合 API 與資料層
- 實作本地通知與排程

**輸出產物**:
- Flutter 頁面程式碼
- 可重用元件
- Riverpod Provider
- API 整合程式碼

**QuitFood UI 頁面**:
- 首頁 (戒食天數、快速打卡)
- 渴望記錄頁
- 統計分析頁
- 社群頁
- 個人設定頁

### @agent-backend-developer (後端開發)
**職責**:
- 設計 API 端點與資料流
- 整合第三方服務 (推播通知)
- 規劃 Edge Functions
- 效能優化與快取策略

**輸出產物**:
- Edge Functions 程式碼
- API 規格文檔
- 錯誤處理策略
- 推播通知整合

---

## 工作流程

```
產品組 README.md → Code Architect → Supabase Architect → Backend Developer → Mobile Developer
                        │                  │                    │                    │
                        ▼                  ▼                    ▼                    ▼
                   架構設計           Schema 設計           Edge Functions        Flutter UI
                   介面定義           RLS 規則              推播服務              狀態管理
                   數據流圖           索引設計              API 整合              本地通知
                        │                  │                    │                    │
                        └──────────────────┴────────────────────┴────────────────────┘
                                                      │
                                                      ▼
                                         Feature 程式碼 (開發組產出)
```

---

## 調用方式

```
請開發組實作 QuitFood 的 [功能名稱]：

1. Code Architect：
   - 設計功能模組的 Clean Architecture
   - 定義 Repository 介面

2. Supabase Architect：
   - 設計相關資料表
   - 定義 RLS 確保用戶資料隔離

3. Backend Developer：
   - 實作 Edge Functions (如需要)
   - 整合推播通知

4. Mobile Developer：
   - 實作 Flutter UI 頁面
   - 使用 Riverpod 管理狀態
```

---

## 技術棧

| 層級 | 技術 | 說明 |
|------|------|------|
| UI | Flutter 3.x | 跨平台 UI |
| 狀態管理 | Riverpod | 響應式狀態 |
| 導航 | go_router | 聲明式路由 |
| 本地儲存 | Hive / Drift | 離線資料 |
| 後端 | Supabase | BaaS |
| 認證 | Supabase Auth | OAuth / Email |
| 資料庫 | PostgreSQL | 關聯式 |
| 推播 | Supabase + FCM | 本地 + 遠端通知 |

---

## 程式碼規範

### Flutter 規範
```dart
// ✅ 正確：使用 const 建構子
const MyWidget({super.key});

// ✅ 正確：明確型別，禁止 dynamic
final List<DailyCheckin> checkins;

// ✅ 正確：Riverpod 狀態管理
final quitJourneyProvider = FutureProvider<QuitJourney?>((ref) async {
  final repository = ref.watch(journeyRepositoryProvider);
  return repository.getCurrentJourney();
});

// ✅ 正確：戒食天數計算
int get quitDays {
  final startDate = journey.startDate;
  return DateTime.now().difference(startDate).inDays;
}
```

### Supabase 規範
```sql
-- ✅ 正確：小寫命名 + 複數表名
CREATE TABLE quit_journeys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
  start_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  end_date TIMESTAMPTZ, -- NULL 表示進行中
  reason TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ✅ 正確：RLS 啟用
ALTER TABLE quit_journeys ENABLE ROW LEVEL SECURITY;

-- ✅ 正確：用戶只能存取自己的資料
CREATE POLICY "Users can only access own journeys"
  ON quit_journeys FOR ALL
  USING (auth.uid() = user_id);
```

---

## QuitFood 特定架構

### Clean Architecture 分層
```
lib/
├── core/                    # 核心工具
│   ├── constants/
│   ├── extensions/
│   └── utils/
├── data/                    # 資料層
│   ├── datasources/
│   │   ├── local/          # Hive/Drift
│   │   └── remote/         # Supabase
│   ├── models/             # DTO
│   └── repositories/       # 實作
├── domain/                  # 領域層
│   ├── entities/           # 業務實體
│   ├── repositories/       # 介面
│   └── usecases/          # 業務邏輯
├── presentation/           # 表現層
│   ├── pages/
│   ├── widgets/
│   └── providers/          # Riverpod
└── main.dart
```

### 核心 Domain Entities
```dart
// 戒食旅程
class QuitJourney {
  final String id;
  final DateTime startDate;
  final DateTime? endDate;
  final String? reason;
}

// 每日打卡
class DailyCheckin {
  final String id;
  final String journeyId;
  final DateTime date;
  final String mood;
  final String? note;
}

// 渴望記錄
class Craving {
  final String id;
  final String journeyId;
  final DateTime timestamp;
  final int intensity; // 1-10
  final String trigger;
  final String? copingStrategy;
  final bool resisted;
}
```

---

## 交付標準

開發組完成後，必須確保：

1. **程式碼品質**:
   - [ ] `flutter analyze` 無錯誤
   - [ ] 無 `dynamic` 型別
   - [ ] 所有 Widget 使用 `const` 建構子

2. **架構合規**:
   - [ ] 遵循 Clean Architecture 分層
   - [ ] Repository 介面與實作分離
   - [ ] Riverpod Provider 正確定義

3. **資料庫安全**:
   - [ ] 所有表啟用 RLS
   - [ ] 外鍵正確設定
   - [ ] 索引覆蓋常用查詢

4. **離線支援**:
   - [ ] 關鍵資料本地快取
   - [ ] 同步衝突處理
   - [ ] 離線狀態 UI 提示
