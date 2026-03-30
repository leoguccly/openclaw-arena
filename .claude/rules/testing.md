# Testing Rules

> **Last Updated**: 2026-02-10
> **Status**: Active
> **Coverage Target**: 80% (Critical paths: 100%)

---

## 1. TDD 工作流程

### 1.1 Red-Green-Refactor 循環

```
┌─────────────────┐
│ 1. Write Test   │ ◀─── 先寫測試 (Red)
│    (Failing)    │
└────────┬────────┘
         ▼
┌─────────────────┐
│ 2. Write Code   │ ◀─── 實作功能 (Green)
│    (Passing)    │
└────────┬────────┘
         ▼
┌─────────────────┐
│ 3. Refactor     │ ◀─── 重構優化
│    (Clean)      │
└────────┬────────┘
         │
         ▼
      Repeat
```

### 1.2 測試先行原則

**CRITICAL**: 對於核心業務邏輯，必須先寫測試

```dart
// 1. 先定義預期行為
test('should generate story with valid config', () async {
  // Given
  final config = StoryConfig(
    theme: 'adventure',
    ageGroup: '4-6',
    language: 'zh-TW',
  );

  // When
  final result = await usecase.execute(config);

  // Then
  expect(result, isA<StoryEntity>());
  expect(result.content.length, greaterThan(100));
});

// 2. 再實作功能
class GenerateStoryUsecase {
  Future<StoryEntity> execute(StoryConfig config) async {
    // Implementation
  }
}
```

---

## 2. 測試金字塔

```
           /\
          /  \
         / E2E\        10% - End-to-End Tests
        /______\
       /        \
      / Widget   \     20% - Widget Tests
     /____________\
    /              \
   /     Unit       \  70% - Unit Tests
  /__________________\
```

### 2.1 Unit Tests (70%)

測試單一函數或類別的邏輯:

```dart
// test/features/story_factory/domain/usecases/generate_story_usecase_test.dart
void main() {
  late GenerateStoryUsecase usecase;
  late MockStoryRepository mockRepository;

  setUp(() {
    mockRepository = MockStoryRepository();
    usecase = GenerateStoryUsecase(mockRepository);
  });

  group('GenerateStoryUsecase', () {
    test('should call repository with correct parameters', () async {
      // Arrange
      final config = StoryConfig.test();
      when(mockRepository.generateStory(any))
          .thenAnswer((_) async => StoryEntity.test());

      // Act
      await usecase.execute(config);

      // Assert
      verify(mockRepository.generateStory(config)).called(1);
    });

    test('should throw ValidationException for invalid age group', () async {
      // Arrange
      final config = StoryConfig(ageGroup: 'invalid');

      // Act & Assert
      expect(
        () => usecase.execute(config),
        throwsA(isA<ValidationException>()),
      );
    });
  });
}
```

### 2.2 Widget Tests (20%)

測試 UI 元件的渲染和交互:

```dart
// test/features/story_factory/presentation/widgets/story_card_test.dart
void main() {
  testWidgets('StoryCard displays title and cover image', (tester) async {
    // Arrange
    final story = StoryEntity(
      id: '1',
      title: 'Test Story',
      coverImageUrl: 'https://example.com/cover.jpg',
    );

    // Act
    await tester.pumpWidget(
      MaterialApp(
        home: StoryCard(story: story),
      ),
    );

    // Assert
    expect(find.text('Test Story'), findsOneWidget);
    expect(find.byType(CachedNetworkImage), findsOneWidget);
  });

  testWidgets('StoryCard onTap callback is triggered', (tester) async {
    // Arrange
    var tapped = false;
    final story = StoryEntity.test();

    // Act
    await tester.pumpWidget(
      MaterialApp(
        home: StoryCard(
          story: story,
          onTap: () => tapped = true,
        ),
      ),
    );
    await tester.tap(find.byType(StoryCard));

    // Assert
    expect(tapped, isTrue);
  });
}
```

### 2.3 Integration Tests (10%)

測試完整的用戶流程:

```dart
// integration_test/story_creation_flow_test.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('User can create a story from start to finish', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    // Navigate to story creation
    await tester.tap(find.text('創建故事'));
    await tester.pumpAndSettle();

    // Select theme
    await tester.tap(find.text('冒險'));
    await tester.pumpAndSettle();

    // Select age group
    await tester.tap(find.text('4-6 歲'));
    await tester.pumpAndSettle();

    // Submit
    await tester.tap(find.text('開始生成'));
    await tester.pumpAndSettle(const Duration(seconds: 30));

    // Verify story is created
    expect(find.byType(StoryDetailPage), findsOneWidget);
  });
}
```

---

## 3. 測試檔案結構

```
test/
├── features/
│   ├── story_factory/
│   │   ├── data/
│   │   │   ├── datasources/
│   │   │   │   └── story_remote_datasource_test.dart
│   │   │   └── repositories/
│   │   │       └── story_repository_impl_test.dart
│   │   ├── domain/
│   │   │   └── usecases/
│   │   │       └── generate_story_usecase_test.dart
│   │   └── presentation/
│   │       ├── pages/
│   │       │   └── create_story_page_test.dart
│   │       └── widgets/
│   │           └── story_card_test.dart
│   └── voice_cloner/
│       └── ...
├── core/
│   ├── utils/
│   │   └── validators_test.dart
│   └── error/
│       └── exceptions_test.dart
├── fixtures/                    # Test data
│   ├── story_fixture.dart
│   └── voice_profile_fixture.dart
├── mocks/                       # Mock classes
│   ├── mock_story_repository.dart
│   └── mock_supabase_client.dart
└── helpers/                     # Test utilities
    ├── pump_app.dart
    └── mock_providers.dart
```

---

## 4. Mock 與 Fixture 規範

### 4.1 使用 Mockito

```dart
// test/mocks/mock_story_repository.dart
import 'package:mockito/annotations.dart';
import 'package:mystory/features/story_factory/domain/repositories/story_repository.dart';

@GenerateMocks([StoryRepository])
void main() {}
```

執行生成: `flutter pub run build_runner build`

### 4.2 Test Fixtures

```dart
// test/fixtures/story_fixture.dart
extension StoryEntityTest on StoryEntity {
  static StoryEntity create({
    String? id,
    String? title,
    String? content,
    DateTime? createdAt,
  }) {
    return StoryEntity(
      id: id ?? 'test-story-id',
      title: title ?? 'Test Story Title',
      content: content ?? 'Test story content...',
      createdAt: createdAt ?? DateTime.now(),
      theme: 'adventure',
      ageGroup: '4-6',
      language: 'zh-TW',
    );
  }
}
```

### 4.3 Riverpod 測試

```dart
// test/helpers/mock_providers.dart
ProviderContainer createContainer({
  List<Override> overrides = const [],
}) {
  return ProviderContainer(
    overrides: [
      // Default mocks
      storyRepositoryProvider.overrideWithValue(MockStoryRepository()),
      ...overrides,
    ],
  );
}

// Usage in tests
test('should load stories', () async {
  final container = createContainer(
    overrides: [
      storyRepositoryProvider.overrideWithValue(mockRepo),
    ],
  );

  final stories = await container.read(storyListProvider.future);
  expect(stories, isNotEmpty);
});
```

---

## 5. Edge Function 測試

### 5.1 本地測試

```bash
# 啟動本地 Supabase
supabase start

# 測試 Edge Function
supabase functions serve generate-story --env-file .env.local

# 使用 curl 測試
curl -X POST http://localhost:54321/functions/v1/generate-story \
  -H "Authorization: Bearer ${ANON_KEY}" \
  -H "Content-Type: application/json" \
  -H "x-user-id: test-user-id" \
  -d '{"story_id": "xxx", "config": {...}}'
```

### 5.2 Deno Test

```typescript
// supabase/functions/generate-story/index.test.ts
import { assertEquals } from "https://deno.land/std@0.168.0/testing/asserts.ts";

Deno.test("should return 400 for missing story_id", async () => {
  const req = new Request("http://localhost/generate-story", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-user-id": "test-user",
    },
    body: JSON.stringify({ config: {} }),
  });

  const res = await handler(req);
  assertEquals(res.status, 400);

  const body = await res.json();
  assertEquals(body.error, "story_id is required");
});
```

---

## 6. 測試命名規範

### 6.1 Describe-It Pattern

```dart
group('StoryRepository', () {
  group('getStories', () {
    test('should return list of stories when successful', () {});
    test('should throw ServerException when API fails', () {});
    test('should return empty list when no stories exist', () {});
  });

  group('createStory', () {
    test('should create story with valid config', () {});
    test('should throw ValidationException for invalid config', () {});
  });
});
```

### 6.2 命名格式

```
should [expected behavior] when [condition]
```

範例:
- `should return story list when API succeeds`
- `should throw AuthException when user is not logged in`
- `should navigate to detail page when card is tapped`

---

## 7. 覆蓋率要求

| 層級 | 覆蓋率目標 | 說明 |
|------|-----------|------|
| Domain (Usecases) | 100% | 核心業務邏輯必須完整測試 |
| Data (Repositories) | 90% | 資料層高覆蓋 |
| Presentation (Providers) | 80% | 狀態管理邏輯 |
| Presentation (Widgets) | 60% | UI 元件 |
| Edge Functions | 90% | 後端服務 |

### 7.1 檢查覆蓋率

```bash
# 執行測試並生成覆蓋率報告
flutter test --coverage

# 查看報告
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html
```

---

## 8. CI/CD 整合

### 8.1 GitHub Actions

```yaml
# .github/workflows/test.yml
name: Test

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.19.0'

      - name: Install dependencies
        run: flutter pub get
        working-directory: app

      - name: Run tests
        run: flutter test --coverage
        working-directory: app

      - name: Check coverage
        run: |
          COVERAGE=$(lcov --summary coverage/lcov.info | grep "lines" | awk '{print $2}' | sed 's/%//')
          if [ $(echo "$COVERAGE < 80" | bc) -eq 1 ]; then
            echo "Coverage $COVERAGE% is below 80%"
            exit 1
          fi
        working-directory: app
```

---

## 9. 測試優先事項

### 9.1 必須測試

- [ ] 認證流程 (登入、登出、Session 刷新)
- [ ] 故事生成流程
- [ ] 聲音克隆流程
- [ ] 付款流程
- [ ] 錯誤處理路徑

### 9.2 建議測試

- [ ] 所有 Usecase
- [ ] 所有 Repository
- [ ] 關鍵 UI 元件
- [ ] 表單驗證

### 9.3 可選測試

- [ ] 純展示型 Widget
- [ ] 工具函數
- [ ] 常數定義

---

## Checklist

- [ ] 核心 Usecase 有 100% 測試覆蓋
- [ ] 每個 PR 包含相關測試
- [ ] 測試可以獨立運行 (無外部依賴)
- [ ] Mock 正確使用，不連接真實 API
- [ ] CI 自動執行測試
- [ ] 覆蓋率不低於 80%
