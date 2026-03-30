# Test Team (測試組) - QuitFood

## 專案背景
QuitFood 是一款幫助用戶戒除不健康飲食習慣的 Flutter App，後端使用 Supabase。

## 角色定位
負責測試規劃、自動化測試、品質驗證與持續整合。

## 團隊成員

### @agent-test-generator (測試分析師)
**職責**:
- 分析需求產出測試案例
- 撰寫 `test_task.md` 測試規範
- 定義測試邊界與覆蓋率目標
- 識別關鍵測試場景

**輸出產物**:
- test_task.md 測試規範
- 測試案例矩陣
- 邊界條件清單
- 測試優先級排序

**QuitFood 測試重點**:
- 戒食天數計算正確性
- 跨時區處理
- 離線/同步場景
- 復發流程正確性

### @agent-test-engineer (測試工程師)
**職責**:
- 設計測試策略與金字塔
- 建立自動化測試框架
- 整合 CI/CD 測試流程
- 分析測試覆蓋率

**輸出產物**:
- 測試策略文檔
- CI/CD 配置
- 覆蓋率報告
- 測試環境設定

### @agent-test-runner (測試執行者)
**職責**:
- 執行自動化測試
- 分析測試失敗原因
- 診斷錯誤根因
- 提供修復建議

**輸出產物**:
- 測試執行報告
- 失敗分析
- 修復建議
- 回歸測試結果

---

## 工作流程

```
開發組程式碼 → Test Generator → Test Engineer → Test Runner
                    │                │               │
                    ▼                ▼               ▼
              測試案例設計      自動化測試實作    測試執行驗證
              test_task.md     Widget Tests      執行報告
              邊界條件         Integration       失敗分析
                    │                │               │
                    └────────────────┴───────────────┘
                                     │
                                     ▼
                         品質報告 (測試組產出)
```

---

## 調用方式

```
請測試組驗證 QuitFood 的 [功能名稱]：

1. Test Generator：
   - 分析功能 README.md
   - 產出測試案例清單
   - 定義戒食計算的邊界條件

2. Test Engineer：
   - 建立 Widget Test
   - 設計 Repository Mock
   - 整合 CI 測試流程

3. Test Runner：
   - 執行 flutter test
   - 分析失敗測試
   - 提供修復建議
```

---

## 測試金字塔

```
                    ┌─────────┐
                    │  E2E    │  10%  - 完整用戶流程
                    │  Tests  │        (Integration Test)
                    ├─────────┤
                    │ Widget  │  30%  - UI 元件測試
                    │  Tests  │        (flutter_test)
                    ├─────────┤
                    │  Unit   │  60%  - 業務邏輯測試
                    │  Tests  │        (Repository, Provider)
                    └─────────┘
```

---

## QuitFood 測試案例範本

### test_task.md 格式
```markdown
# QuitFood 測試規範 - [功能名稱]

## 單元測試 (Unit Tests)

### QuitJourneyRepository
- [ ] `startNewJourney()` - 成功建立新的戒食旅程
- [ ] `startNewJourney()` - 有進行中旅程時應先結束舊旅程
- [ ] `getCurrentJourney()` - 成功取得進行中的旅程
- [ ] `getCurrentJourney()` - 無進行中旅程時回傳 null
- [ ] `endJourney()` - 成功結束旅程並記錄原因

### QuitDaysCalculator
- [ ] `calculate()` - 正確計算戒食天數
- [ ] `calculate()` - 跨午夜正確計算
- [ ] `calculate()` - 跨時區正確計算
- [ ] `calculate()` - 開始日當天算第 1 天

### CravingRepository
- [ ] `recordCraving()` - 成功記錄渴望
- [ ] `recordCraving()` - 強度超出範圍 (1-10) 應拋出異常
- [ ] `getCravingsForJourney()` - 正確取得旅程內所有渴望
- [ ] `getResistanceRate()` - 正確計算抵抗成功率

## Widget 測試 (Widget Tests)

### HomePage
- [ ] 顯示當前戒食天數
- [ ] 顯示快速打卡按鈕
- [ ] 無進行中旅程時顯示開始按鈕
- [ ] 點擊打卡後顯示成功動畫

### CravingRecordPage
- [ ] 顯示強度滑桿 (1-10)
- [ ] 選擇觸發因素後啟用送出按鈕
- [ ] 成功記錄後顯示鼓勵訊息
- [ ] 成功抵抗時顯示特殊肯定

### StatisticsPage
- [ ] 正確顯示總戒食天數
- [ ] 正確顯示渴望抵抗率
- [ ] 正確顯示打卡連續天數
- [ ] 無資料時顯示空狀態

## 整合測試 (Integration Tests)

### 戒食流程
- [ ] 開始戒食 → 每日打卡 → 查看統計
- [ ] 記錄渴望 → 成功抵抗 → 獲得成就
- [ ] 復發 → 結束旅程 → 重新開始

### 離線場景
- [ ] 離線時可以打卡
- [ ] 離線時可以記錄渴望
- [ ] 恢復連線後正確同步
```

---

## Flutter 測試範例

### Widget Test
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

class MockJourneyRepository extends Mock implements QuitJourneyRepository {}

void main() {
  group('HomePage', () {
    late MockJourneyRepository mockRepository;

    setUp(() {
      mockRepository = MockJourneyRepository();
    });

    testWidgets('顯示當前戒食天數', (tester) async {
      when(() => mockRepository.getCurrentJourney()).thenAnswer(
        (_) async => QuitJourney(
          id: '1',
          startDate: DateTime.now().subtract(const Duration(days: 7)),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            journeyRepositoryProvider.overrideWithValue(mockRepository),
          ],
          child: const MaterialApp(
            home: HomePage(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('7'), findsOneWidget);
      expect(find.text('天'), findsOneWidget);
    });

    testWidgets('無進行中旅程時顯示開始按鈕', (tester) async {
      when(() => mockRepository.getCurrentJourney()).thenAnswer(
        (_) async => null,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            journeyRepositoryProvider.overrideWithValue(mockRepository),
          ],
          child: const MaterialApp(
            home: HomePage(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('開始戒食之旅'), findsOneWidget);
    });
  });
}
```

### Unit Test
```dart
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('QuitDaysCalculator', () {
    late QuitDaysCalculator calculator;

    setUp(() {
      calculator = QuitDaysCalculator();
    });

    test('正確計算戒食天數', () {
      final startDate = DateTime(2024, 1, 1);
      final now = DateTime(2024, 1, 8);

      final days = calculator.calculate(startDate: startDate, now: now);

      expect(days, 8); // 1/1 到 1/8 = 8 天
    });

    test('開始日當天算第 1 天', () {
      final startDate = DateTime(2024, 1, 1, 10, 0);
      final now = DateTime(2024, 1, 1, 23, 0);

      final days = calculator.calculate(startDate: startDate, now: now);

      expect(days, 1);
    });

    test('跨午夜正確計算', () {
      final startDate = DateTime(2024, 1, 1, 23, 59);
      final now = DateTime(2024, 1, 2, 0, 1);

      final days = calculator.calculate(startDate: startDate, now: now);

      expect(days, 2); // 跨日應算第 2 天
    });
  });

  group('CravingRepository', () {
    test('強度超出範圍應拋出異常', () {
      final repository = CravingRepository();

      expect(
        () => repository.recordCraving(intensity: 15, trigger: 'stress'),
        throwsA(isA<InvalidIntensityException>()),
      );
    });
  });
}
```

---

## CI/CD 測試配置

### GitHub Actions 範例
```yaml
name: Flutter Tests

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.x'

      - name: Install dependencies
        run: flutter pub get

      - name: Analyze
        run: flutter analyze

      - name: Run tests
        run: flutter test --coverage

      - name: Check coverage
        run: |
          # 確保覆蓋率 > 80%
          lcov --summary coverage/lcov.info
```

---

## 交付標準

測試組完成後，必須確保：

1. **測試覆蓋率**:
   - [ ] Unit Tests 覆蓋率 > 80%
   - [ ] Widget Tests 覆蓋關鍵頁面
   - [ ] 所有 Edge Cases 有對應測試

2. **測試品質**:
   - [ ] `flutter test` 全部通過
   - [ ] 無 flaky tests (不穩定測試)
   - [ ] 測試執行時間 < 2 分鐘

3. **文檔完整**:
   - [ ] test_task.md 更新完成
   - [ ] 測試案例與需求對應
   - [ ] 失敗測試有修復建議

4. **QuitFood 特定驗證**:
   - [ ] 戒食天數計算在各種邊界條件下正確
   - [ ] 離線場景正確處理
   - [ ] 復發流程不會丟失資料
