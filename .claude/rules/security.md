# Security Rules

> **Last Updated**: 2026-02-10
> **Status**: Active
> **Severity**: CRITICAL - 違反這些規則可能導致安全漏洞

---

## 1. API Keys & Secrets 管理

### 1.1 絕對禁止硬編碼

```dart
// ❌ NEVER DO THIS
const apiKey = "sk-abc123...";
final geminiKey = "AIza...";

// ✅ ALWAYS USE ENVIRONMENT VARIABLES
final apiKey = Platform.environment['API_KEY'];
// Or for Supabase Edge Functions:
final apiKey = Deno.env.get("GEMINI_API_KEY");
```

### 1.2 第三方 API 呼叫原則

**CRITICAL RULE**: 所有第三方 API (Gemini, Fish Audio, OpenAI, etc.) 必須透過 Supabase Edge Functions 呼叫

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│ Flutter App │ ──▶ │ Edge Function    │ ──▶ │ Third-party API │
│ (No API Key)│     │ (API Key in Env) │     │ (Gemini, etc.)  │
└─────────────┘     └──────────────────┘     └─────────────────┘
```

**原因**:
- API Keys 不應出現在 Client 端程式碼
- 可在 Server 端實作 Rate Limiting、Usage Tracking
- 可以更換 API Provider 而不需更新 App

### 1.3 Secrets 存放位置

| 環境 | 存放位置 | 範例 |
|------|---------|------|
| Supabase Edge Functions | Supabase Secrets | `supabase secrets set GEMINI_API_KEY=xxx` |
| Local Development | `.env` (gitignored) | `GEMINI_API_KEY=xxx` |
| CI/CD | GitHub Secrets | Settings > Secrets > Actions |

---

## 2. Supabase Flutter SDK 已知問題與 Workarounds

### 2.1 Edge Function 認證問題 (GitHub #21970)

**問題描述**: Supabase Flutter SDK 的 `functions.invoke()` 無法正確傳遞自訂 headers 到 Edge Function。

**症狀**: Edge Function 收到 401 Invalid JWT 錯誤，即使 Flutter 端有有效的 Session。

**Workaround**: 使用 `x-user-id` header 作為備援認證

#### Flutter Client 端實作

```dart
// voice_remote_datasource.dart / story_remote_datasource.dart
final accessToken = supabaseClient.auth.currentSession?.accessToken;
final currentUserId = _getUserId();

final response = await supabaseClient.functions.invoke(
  'your-function-name',
  body: { /* your data */ },
  headers: {
    // 主要認證方式 (可能因 SDK bug 失效)
    if (accessToken != null) 'Authorization': 'Bearer $accessToken',
    // 備援認證方式 (Workaround)
    'x-user-id': currentUserId,
    'x-user-email': supabaseClient.auth.currentUser?.email ?? '',
  },
);
```

#### Edge Function 端實作

```typescript
// _shared/supabase-client.ts
export async function getUserFromAuth(
  authHeader: string | null,
  req?: Request
): Promise<{ id: string; email: string } | null> {

  // PRIORITY 1: Check x-user-id header (workaround for Flutter SDK bug)
  if (req) {
    const userId = req.headers.get('x-user-id');
    const userEmail = req.headers.get('x-user-email') || '';
    if (userId && userId.length > 0) {
      console.log(`[auth] Using x-user-id header: ${userId}`);
      return { id: userId, email: userEmail };
    }
  }

  // PRIORITY 2: Try JWT from Authorization header
  if (authHeader && authHeader.startsWith('Bearer ')) {
    try {
      const token = authHeader.replace('Bearer ', '');
      const { data: { user }, error } = await supabase.auth.getUser(token);
      if (!error && user) {
        return { id: user.id, email: user.email || '' };
      }
    } catch (e) {
      console.error('[auth] JWT verification failed:', e);
    }
  }

  return null;
}
```

**追蹤**: https://github.com/supabase/supabase-flutter/issues/21970

### 2.2 Session 刷新最佳實踐

```dart
// 在關鍵操作前顯式刷新 Session
try {
  await supabaseClient.auth.refreshSession();
} catch (_) {
  // 忽略刷新失敗，繼續使用當前 Token
}
```

---

## 3. RLS (Row Level Security) 規範

### 3.1 必須啟用 RLS

所有包含用戶資料的表必須啟用 RLS:

```sql
ALTER TABLE your_table ENABLE ROW LEVEL SECURITY;
```

### 3.2 標準 RLS Policy 模板

```sql
-- 用戶只能讀取自己的資料
CREATE POLICY "Users can read own data"
ON your_table FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- 用戶只能新增自己的資料
CREATE POLICY "Users can insert own data"
ON your_table FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

-- 用戶只能更新自己的資料
CREATE POLICY "Users can update own data"
ON your_table FOR UPDATE
TO authenticated
USING (auth.uid() = user_id)
WITH CHECK (auth.uid() = user_id);

-- 用戶只能刪除自己的資料
CREATE POLICY "Users can delete own data"
ON your_table FOR DELETE
TO authenticated
USING (auth.uid() = user_id);
```

---

## 4. 輸入驗證

### 4.1 Edge Function 輸入驗證

```typescript
// 驗證必要參數
if (!body.story_id || typeof body.story_id !== 'string') {
  return new Response(
    JSON.stringify({ error: 'story_id is required and must be a string' }),
    { status: 400, headers: corsHeaders }
  );
}

// 驗證 UUID 格式
const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
if (!uuidRegex.test(body.story_id)) {
  return new Response(
    JSON.stringify({ error: 'Invalid story_id format' }),
    { status: 400, headers: corsHeaders }
  );
}
```

### 4.2 Flutter 端輸入驗證

```dart
// 使用 Freezed + json_serializable 確保類型安全
@freezed
class StoryConfig with _$StoryConfig {
  const factory StoryConfig({
    required String theme,
    required String ageGroup,
    required String language,
    @Default(5) int estimatedMinutes,
  }) = _StoryConfig;

  factory StoryConfig.fromJson(Map<String, dynamic> json) =>
      _$StoryConfigFromJson(json);
}
```

---

## 5. CORS 配置

### 5.1 標準 CORS Headers

```typescript
// _shared/cors.ts
export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-user-id, x-user-email',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};
```

**注意**: 生產環境應將 `Access-Control-Allow-Origin` 設為具體的域名。

---

## 6. 敏感資料處理

### 6.1 不記錄敏感資訊

```typescript
// ❌ NEVER LOG
console.log('User token:', accessToken);
console.log('API Key:', apiKey);

// ✅ SAFE LOGGING
console.log('User ID:', userId);
console.log('Request received for story:', storyId);
```

### 6.2 錯誤訊息不暴露內部細節

```typescript
// ❌ NEVER EXPOSE INTERNAL ERRORS
return new Response(JSON.stringify({
  error: `Database error: ${e.message}, Stack: ${e.stack}`
}));

// ✅ GENERIC ERROR MESSAGES
return new Response(JSON.stringify({
  error: 'An error occurred. Please try again.'
}));

// Log detailed error internally
console.error('[internal]', e);
```

---

## 7. 兒童隱私保護 (COPPA/GDPR)

### 7.1 數據最小化原則

只收集業務必需的資料:
- ✅ 兒童暱稱
- ✅ 年齡範圍 (不需要精確生日)
- ✅ 興趣標籤
- ❌ 真實姓名
- ❌ 精確地理位置
- ❌ 照片 (除非必要且有家長同意)

### 7.2 家長同意機制

```dart
// 任何兒童資料操作前必須驗證家長同意
if (!await parentalConsentRepository.hasValidConsent(childId)) {
  throw const ParentalConsentRequiredException();
}
```

---

## Checklist

開發時請確認:

- [ ] API Keys 存放在 Supabase Secrets 或 `.env`
- [ ] 第三方 API 透過 Edge Functions 呼叫
- [ ] Edge Functions 使用 `x-user-id` workaround
- [ ] 所有用戶資料表啟用 RLS
- [ ] 輸入參數有驗證
- [ ] 錯誤訊息不暴露內部細節
- [ ] 敏感資料不記錄在 logs
