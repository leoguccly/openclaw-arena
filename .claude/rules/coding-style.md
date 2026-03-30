# Coding Style Rules

> **Last Updated**: 2026-02-10
> **Status**: Active
> **Scope**: Flutter (Dart) + Supabase Edge Functions (TypeScript/Deno)

---

## 1. 型別安全 (Type Safety)

### 1.1 零 Dynamic 政策 (Flutter/Dart)

**CRITICAL**: 從 Supabase 到 UI，全程型別安全

```dart
// ❌ NEVER USE
dynamic data = response.data;
Map<String, dynamic> json = ...;  // 僅允許在 JSON 解析入口

// ✅ ALWAYS USE TYPED MODELS
final StoryEntity story = StoryEntity.fromJson(response.data);
```

### 1.2 Freezed + json_serializable 必須使用

所有資料模型必須使用 Freezed:

```dart
import 'package:freezed_annotation/freezed_annotation.dart';

part 'story_entity.freezed.dart';
part 'story_entity.g.dart';

@freezed
class StoryEntity with _$StoryEntity {
  const factory StoryEntity({
    required String id,
    required String title,
    required String content,
    required DateTime createdAt,
    @Default(false) bool isFavorite,
    String? coverImageUrl,
  }) = _StoryEntity;

  factory StoryEntity.fromJson(Map<String, dynamic> json) =>
      _$StoryEntityFromJson(json);
}
```

### 1.3 TypeScript Strict Mode (Edge Functions)

```typescript
// tsconfig.json or deno.json
{
  "compilerOptions": {
    "strict": true,
    "noImplicitAny": true,
    "strictNullChecks": true
  }
}
```

---

## 2. 架構模式 (Architecture Patterns)

### 2.1 Clean Architecture 目錄結構

```
lib/features/{feature_name}/
├── data/
│   ├── datasources/          # Remote & Local data sources
│   │   ├── {name}_remote_datasource.dart
│   │   └── {name}_local_datasource.dart
│   ├── models/               # Data Transfer Objects
│   │   └── {name}_model.dart
│   └── repositories/         # Repository implementations
│       └── {name}_repository_impl.dart
├── domain/
│   ├── entities/             # Business entities
│   │   └── {name}_entity.dart
│   ├── repositories/         # Repository interfaces
│   │   └── {name}_repository.dart
│   └── usecases/             # Business logic
│       └── {verb}_{noun}_usecase.dart
├── presentation/
│   ├── pages/                # Full screen widgets
│   │   └── {name}_page.dart
│   ├── widgets/              # Reusable UI components
│   │   └── {name}_widget.dart
│   └── providers/            # Riverpod providers & state
│       ├── {name}_providers.dart
│       └── {name}_state.dart
└── README.md                 # Feature documentation (REQUIRED)
```

### 2.2 Feature README 必須包含

每個 Feature 目錄必須有 `README.md`，作為唯一真理來源:

1. **用戶故事 (User Stories)**
2. **UI Task 清單**
3. **資料結構定義**
4. **API 端點規格**
5. **測試驗收標準**

---

## 3. 狀態管理 (Riverpod)

### 3.1 Provider 命名規範

```dart
// Async data provider
final storyListProvider = FutureProvider.autoDispose<List<StoryEntity>>((ref) {
  return ref.watch(storyRepositoryProvider).getStories();
});

// State notifier provider
final storyDetailNotifierProvider = StateNotifierProvider.autoDispose
    .family<StoryDetailNotifier, AsyncValue<StoryEntity>, String>((ref, storyId) {
  return StoryDetailNotifier(ref, storyId);
});

// Simple provider
final currentUserIdProvider = Provider<String?>((ref) {
  return ref.watch(authStateProvider).valueOrNull?.id;
});
```

### 3.2 State 必須使用 Freezed

```dart
@freezed
class StoryState with _$StoryState {
  const factory StoryState.initial() = _Initial;
  const factory StoryState.loading() = _Loading;
  const factory StoryState.loaded(StoryEntity story) = _Loaded;
  const factory StoryState.error(String message) = _Error;
}
```

### 3.3 autoDispose 原則

- 頁面級 Provider: 使用 `autoDispose`
- 全域狀態 (Auth, Settings): 不使用 `autoDispose`

---

## 4. UI 風格 (莫蘭迪極簡風)

### 4.1 色彩規範

```dart
// core/theme/colors.dart
class AppColors {
  // 主色調 - 莫蘭迪灰藍
  static const primary = Color(0xFF8B9EB7);
  static const primaryLight = Color(0xFFB4C4D6);
  static const primaryDark = Color(0xFF5E7491);

  // 背景色 - 暖灰
  static const backgroundLight = Color(0xFFF8F6F4);
  static const surfaceLight = Color(0xFFFFFFFF);

  // 文字色
  static const textMain = Color(0xFF2D3142);
  static const textMuted = Color(0xFF9A9A9A);

  // 語義色 (低飽和度)
  static const success = Color(0xFF7EB09B);
  static const warning = Color(0xFFD4A574);
  static const error = Color(0xFFCD8B8B);
  static const info = Color(0xFF8BAEC4);
}
```

### 4.2 間距系統

```dart
class AppDimensions {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}
```

### 4.3 圓角規範

```dart
static const borderRadiusSm = BorderRadius.all(Radius.circular(8));
static const borderRadiusMd = BorderRadius.all(Radius.circular(12));
static const borderRadiusLg = BorderRadius.all(Radius.circular(16));
static const borderRadiusFull = BorderRadius.all(Radius.circular(999));
```

---

## 5. Edge Function 風格 (TypeScript/Deno)

### 5.1 標準結構

```typescript
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { getSupabaseAdmin, getUserFromAuth } from "../_shared/supabase-client.ts";

serve(async (req: Request) => {
  // 1. CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const supabase = getSupabaseAdmin();

  try {
    // 2. Authentication
    const user = await getUserFromAuth(req.headers.get('Authorization'), req);
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 3. Parse request body
    const body = await req.json();

    // 4. Validate input
    if (!body.required_field) {
      return new Response(
        JSON.stringify({ error: 'required_field is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 5. Business logic
    // ...

    // 6. Success response
    return new Response(
      JSON.stringify({ success: true, data: result }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error: unknown) {
    console.error("[function-name] Error:", error);
    const errorMessage = error instanceof Error ? error.message : 'Unknown error';
    return new Response(
      JSON.stringify({ error: errorMessage }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
```

### 5.2 Logging 規範

```typescript
// 使用一致的 log 格式
console.log(`[function-name] Starting process for user ${userId}`);
console.log(`[function-name] Config: ${JSON.stringify(config)}`);
console.error(`[function-name] Error:`, error);
```

---

## 6. 命名規範

### 6.1 Dart 命名

| 類型 | 規範 | 範例 |
|------|------|------|
| 類別 | UpperCamelCase | `StoryEntity`, `VoiceProfileModel` |
| 變數/函數 | lowerCamelCase | `storyList`, `getVoiceProfiles()` |
| 常數 | lowerCamelCase | `defaultTimeout`, `maxRetries` |
| 檔案 | snake_case | `story_entity.dart`, `voice_providers.dart` |
| 私有成員 | _prefix | `_isLoading`, `_handleError()` |

### 6.2 TypeScript 命名

| 類型 | 規範 | 範例 |
|------|------|------|
| Interface | PascalCase | `StoryConfig`, `UserProfile` |
| 變數/函數 | camelCase | `storyId`, `generateStory()` |
| 常數 | UPPER_SNAKE_CASE | `MAX_RETRIES`, `DEFAULT_TIMEOUT` |
| 檔案 | kebab-case | `generate-story.ts`, `voice-clone.ts` |

---

## 7. 錯誤處理

### 7.1 Flutter 自訂例外

```dart
// core/error/exceptions.dart
abstract class AppException implements Exception {
  final String message;
  final StackTrace? stackTrace;
  const AppException(this.message, [this.stackTrace]);
}

class AuthenticationException extends AppException {
  const AuthenticationException([String message = 'Authentication failed'])
      : super(message);
}

class ServerException extends AppException {
  final int? statusCode;
  const ServerException(super.message, {this.statusCode, super.stackTrace});
}
```

### 7.2 Result Pattern (Optional)

```dart
@freezed
class Result<T> with _$Result<T> {
  const factory Result.success(T data) = Success<T>;
  const factory Result.failure(AppException error) = Failure<T>;
}
```

---

## 8. 禁止事項

### 8.1 Flutter

- ❌ 使用 `dynamic` 類型
- ❌ 使用 `print()` (使用 `AppLogger`)
- ❌ 在 Widget 中直接呼叫 API
- ❌ 硬編碼字串 (使用 l10n)
- ❌ 巨型 Widget (超過 200 行應拆分)

### 8.2 Edge Functions

- ❌ 硬編碼 API Keys
- ❌ 暴露內部錯誤訊息
- ❌ 忽略 CORS headers
- ❌ 不驗證用戶身份
- ❌ 不驗證輸入參數

---

## Checklist

- [ ] 所有資料模型使用 Freezed
- [ ] Provider 使用正確的命名規範
- [ ] UI 遵循莫蘭迪色彩系統
- [ ] Edge Function 遵循標準結構
- [ ] 錯誤使用自訂 Exception 類別
- [ ] 沒有使用 `dynamic` 或 `print()`
