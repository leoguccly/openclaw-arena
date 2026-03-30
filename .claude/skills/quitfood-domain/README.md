# QuitFood Domain Knowledge

> **專案特定知識**: QuitFood 戒食習慣養成 App 的領域知識

## 專案概述

QuitFood 是一款幫助用戶戒除不健康飲食習慣的 App。

### 技術棧
- **前端**: Flutter 3.x + Riverpod
- **後端**: Supabase (PostgreSQL + Edge Functions)
- **架構**: Clean Architecture
- **特性**: 離線優先 (Offline-first)

### 目標用戶
- 想要戒除特定食物（如甜食、垃圾食品）的人
- 情緒性進食者
- 因健康原因需要避免特定食物的人

## 核心功能域

### 1. 戒食追蹤 (Journey Tracking)

**用戶旅程**:
```
開始戒食 → 每日打卡 → 記錄渴望 → 獲得成就 → (可能) 復發 → 重新開始
```

**關鍵計算**:
- 戒食天數：開始日算第 1 天
- 需考慮跨時區情況
- 使用本地日期計算

```dart
/// 計算戒食天數
int get quitDays {
  final localNow = DateTime.now();
  final localStart = startDate.toLocal();
  final nowDate = DateTime(localNow.year, localNow.month, localNow.day);
  final startDateOnly = DateTime(localStart.year, localStart.month, localStart.day);
  return nowDate.difference(startDateOnly).inDays + 1;
}
```

### 2. 渴望管理 (Craving Management)

**渴望強度**: 1-10 分
- 1-3: 輕微渴望
- 4-6: 中等渴望
- 7-10: 強烈渴望

**常見觸發因素**:
- 壓力 (stress)
- 無聊 (boredom)
- 社交場合 (social)
- 情緒低落 (sadness)
- 疲勞 (fatigue)
- 習慣時間 (habit_time)

**應對策略**:
- 喝水
- 散步
- 深呼吸
- 找人聊天
- 做其他活動分散注意力

### 3. 成就系統 (Achievement System)

**里程碑成就**:
| 代碼 | 名稱 | 條件 |
|------|------|------|
| first_day | 第一步 | 完成第 1 天 |
| three_days | 堅持三天 | 完成第 3 天 |
| one_week | 一週達人 | 完成第 7 天 |
| two_weeks | 半月之星 | 完成第 14 天 |
| one_month | 月度冠軍 | 完成第 30 天 |

**行為成就**:
| 代碼 | 名稱 | 條件 |
|------|------|------|
| first_resist | 初次抵抗 | 首次成功抵抗渴望 |
| craving_master | 渴望剋星 | 成功抵抗 10 次渴望 |
| streak_king | 打卡之王 | 連續打卡 14 天 |

### 4. 復發處理 (Relapse Handling)

**設計原則**: 正向心理，不責備

**UI 文案**:
- ❌ 錯誤：「你失敗了」
- ✅ 正確：「沒關係，重新開始也是勇氣」

**資料處理**:
- 結束當前旅程，記錄 end_date 和 end_reason
- 保留歷史資料供統計
- 允許立即開始新旅程

## 資料模型

### 核心 Entity

```dart
// 戒食旅程
class QuitJourney {
  final String id;
  final String userId;
  final String targetFood;      // 要戒除的食物
  final DateTime startDate;
  final DateTime? endDate;      // null = 進行中
  final String? endReason;
  final DateTime createdAt;
}

// 每日打卡
class DailyCheckin {
  final String id;
  final String journeyId;
  final String userId;
  final DateTime checkinDate;   // 只記錄日期
  final String mood;            // great/good/okay/tough/struggling
  final String? note;
}

// 渴望記錄
class Craving {
  final String id;
  final String journeyId;
  final String userId;
  final int intensity;          // 1-10
  final String? trigger;
  final String? copingStrategy;
  final bool resisted;          // 是否成功抵抗
  final DateTime occurredAt;
}

// 成就
class Achievement {
  final String id;
  final String userId;
  final String achievementType;
  final DateTime unlockedAt;
  final Map<String, dynamic>? metadata;
}
```

### 資料庫 Schema

```sql
-- 核心表
quit_journeys        -- 戒食旅程
daily_checkins       -- 每日打卡
cravings            -- 渴望記錄
achievements        -- 成就徽章
user_profiles       -- 用戶擴展資料

-- 關聯
daily_checkins.journey_id → quit_journeys.id
cravings.journey_id → quit_journeys.id
quit_journeys.user_id → auth.users.id
```

## UI/UX 設計原則

### 色彩心理學

| 用途 | 顏色 | 理由 |
|------|------|------|
| 主色調 | 療癒綠 (#6B9080) | 平靜、自然、成長 |
| 成功 | 柔和綠 (#84A98C) | 正向肯定 |
| 警告 | 溫暖橙 (#F6BD60) | 提醒但不緊張 |
| 錯誤 | 柔和紅 (#E07A5F) | 提示但不責備 |

### 正向語言設計

| 情境 | ❌ 避免 | ✅ 使用 |
|------|--------|--------|
| 復發 | 失敗了 | 重新開始也是勇氣 |
| 渴望 | 又想吃了 | 渴望來襲，你可以的 |
| 統計 | 失敗次數 | 歷史旅程 |
| 天數 | 剩餘天數 | 已堅持天數 |

### 關鍵互動

1. **快速打卡**: 首頁一鍵完成
2. **渴望求助**: 隨時可觸及的「渴望來襲」按鈕
3. **即時鼓勵**: 打卡後的慶祝動畫
4. **里程碑慶祝**: 達成成就時的特殊提示

## 離線策略

### 優先級

| 功能 | 離線支援 | 說明 |
|------|---------|------|
| 查看天數 | ✅ 完全支援 | 本地計算 |
| 打卡 | ✅ 完全支援 | 本地儲存，稍後同步 |
| 記錄渴望 | ✅ 完全支援 | 本地儲存，稍後同步 |
| 查看統計 | ⚠️ 部分支援 | 使用快取資料 |
| 社群功能 | ❌ 需要網路 | 顯示離線提示 |

### 同步策略

```
1. 所有寫入操作先存本地
2. 標記為 pending sync
3. 網路恢復時背景同步
4. 同步成功後標記為 synced
5. 衝突處理：本地優先
```

## 測試重點

### 關鍵邊界條件

1. **戒食天數計算**
   - 開始日當天
   - 跨午夜
   - 跨時區
   - 過去日期開始

2. **渴望強度**
   - 邊界值 1 和 10
   - 超出範圍 0 和 11

3. **離線同步**
   - 離線時多次打卡
   - 網路恢復時的順序
   - 衝突情況

4. **成就解鎖**
   - 剛好達成條件
   - 重複解鎖防止
   - 跨旅程統計
