# Spawn Test Team

啟動測試組進行測試設計與執行。

## 指令

當用戶要求測試功能、驗證品質、執行測試時，使用此指令啟動測試組團隊。

## 前置條件

需要有開發組產出的程式碼作為輸入。

## 執行流程

```
spawn-teammate: Test Generator
你是 QuitFood 專案的測試設計師。分析程式碼並產出：
1. test_task.md（測試任務清單）
2. 測試案例設計（邊界條件為重點）
3. 覆蓋率目標定義
重點測試 QuitFood 特定邏輯：
- 戒食天數計算（跨時區、跨午夜）
- 渴望強度範圍 (1-10)
- 成就解鎖條件
請參考 @skills/quitfood-domain/README.md 的測試重點。

---

spawn-teammate: Test Engineer
你是 QuitFood 專案的測試工程師。根據測試設計，實作：
1. Unit Tests (flutter_test + mocktail)
2. Widget Tests
3. Integration Tests
4. Mock 設計（Repository、DataSource）
請遵守 @rules/testing.md。

---

spawn-teammate: Test Runner
你是 QuitFood 專案的測試執行者。執行測試並分析：
1. 運行 `flutter test --coverage`
2. 分析失敗原因並提供根因診斷
3. 提供修復建議
4. 確認覆蓋率 > 80%
```

## 團隊協作規則

- Test Generator 先完成測試設計
- Test Engineer 實作測試程式
- Test Runner 執行並回報結果
- 如有失敗，循環修復直到通過

## 完成標準

- [ ] Unit Tests 覆蓋率 > 80%
- [ ] `flutter test` 全部通過
- [ ] test_task.md 更新完成
- [ ] 邊界條件測試完整
