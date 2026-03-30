# Git Workflow Rules

> **Last Updated**: 2026-02-10
> **Status**: Active
> **Branch Strategy**: GitHub Flow

---

## 1. Branch 命名規範

### 1.1 Branch 類型

| 類型 | 格式 | 範例 | 用途 |
|------|------|------|------|
| Feature | `feature/{ticket}-{description}` | `feature/STORY-123-voice-cloning` | 新功能開發 |
| Bugfix | `bugfix/{ticket}-{description}` | `bugfix/STORY-456-auth-token-fix` | Bug 修復 |
| Hotfix | `hotfix/{description}` | `hotfix/critical-payment-issue` | 緊急修復 |
| Refactor | `refactor/{description}` | `refactor/story-repository` | 重構 |
| Docs | `docs/{description}` | `docs/api-documentation` | 文檔更新 |

### 1.2 Branch 規則

- `main` - 永遠可部署，受保護
- 所有變更必須透過 PR 合併
- PR 需要至少 1 個 Approval
- CI 測試必須通過

---

## 2. Commit Message 規範

### 2.1 Conventional Commits 格式

```
<type>(<scope>): <subject>

[optional body]

[optional footer]
```

### 2.2 Type 類型

| Type | 說明 | 範例 |
|------|------|------|
| `feat` | 新功能 | `feat(voice): add voice cloning API` |
| `fix` | Bug 修復 | `fix(auth): resolve JWT validation issue` |
| `docs` | 文檔變更 | `docs(readme): update setup instructions` |
| `style` | 格式變更 (不影響邏輯) | `style(lint): fix formatting issues` |
| `refactor` | 重構 (不影響功能) | `refactor(story): extract repository` |
| `perf` | 效能優化 | `perf(list): optimize story loading` |
| `test` | 測試相關 | `test(voice): add unit tests for cloning` |
| `chore` | 維護工作 | `chore(deps): update dependencies` |
| `ci` | CI/CD 變更 | `ci(github): add test workflow` |

### 2.3 Scope 範圍

| Scope | 說明 |
|-------|------|
| `auth` | 認證相關 |
| `voice` | 聲音克隆功能 |
| `story` | 故事功能 |
| `player` | 播放器功能 |
| `parental` | 家長控制 |
| `ui` | UI 元件 |
| `api` | API/Edge Functions |
| `db` | 資料庫 |
| `deps` | 依賴項 |

### 2.4 Commit 範例

```bash
# 功能新增
feat(voice): implement Fish Audio voice cloning integration

Add createVoiceModelWithFishAudio method to VoiceRemoteDataSource.
Includes x-user-id header workaround for Supabase SDK bug #21970.

Closes #123

# Bug 修復
fix(auth): resolve 401 error in Edge Functions

Root cause: Supabase Flutter SDK doesn't pass custom headers correctly.
Workaround: Use x-user-id header as fallback authentication.

See: https://github.com/supabase/supabase-flutter/issues/21970

# 重構
refactor(story): extract story generation logic to usecase

Move business logic from provider to GenerateStoryUsecase.
No functional changes.

# 文檔
docs(rules): add security and coding-style rules

Add .claude/rules/ directory with:
- security.md: API key management, SDK workarounds
- coding-style.md: Flutter and TypeScript standards
```

---

## 3. PR 規範

### 3.1 PR Title 格式

```
<type>(<scope>): <short description>
```

範例:
- `feat(voice): add voice cloning functionality`
- `fix(auth): resolve JWT validation in Edge Functions`

### 3.2 PR Description 模板

```markdown
## Summary
<!-- 1-3 bullet points describing what this PR does -->
- Implement voice cloning using Fish Audio API
- Add x-user-id header workaround for Supabase SDK bug
- Update voice profile model with fish_audio_model_id

## Changes
<!-- List the key changes -->
- `voice_remote_datasource.dart`: Add createVoiceModelWithFishAudio method
- `supabase-client.ts`: Prioritize x-user-id header
- `007_migration.sql`: Add fish_audio_model_id column

## Test Plan
<!-- How was this tested? -->
- [ ] Unit tests for new usecase
- [ ] Widget tests for UI changes
- [ ] Manual testing on iOS simulator
- [ ] Edge Function tested via curl

## Screenshots (if applicable)
<!-- Add screenshots for UI changes -->

## Related Issues
<!-- Link related issues -->
Closes #123
Related to #456

---
🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

### 3.3 PR Checklist

```markdown
## Checklist
- [ ] Code follows project coding style
- [ ] Tests added/updated for changes
- [ ] Documentation updated if needed
- [ ] No hardcoded secrets or API keys
- [ ] Edge Functions use x-user-id workaround
- [ ] PR title follows conventional commits
```

---

## 4. Merge 策略

### 4.1 Squash and Merge (預設)

- 將所有 commits 壓縮為一個
- 使用 PR title 作為 commit message
- 保持 main branch 歷史清晰

### 4.2 Rebase and Merge (大型 feature)

- 保留所有 commits
- 適用於需要保留詳細歷史的情況

### 4.3 禁止事項

- ❌ 直接 push 到 `main`
- ❌ Force push 到 `main`
- ❌ Merge without PR
- ❌ Merge 未通過 CI 的 PR

---

## 5. Release 流程

### 5.1 版本號規範 (SemVer)

```
MAJOR.MINOR.PATCH

1.0.0 - 初始正式版
1.1.0 - 新增功能 (向後相容)
1.1.1 - Bug 修復
2.0.0 - 重大變更 (不向後相容)
```

### 5.2 Release Tag

```bash
# 創建 tag
git tag -a v1.2.0 -m "Release v1.2.0: Voice Cloning Feature"

# 推送 tag
git push origin v1.2.0
```

### 5.3 Release Notes 格式

```markdown
## v1.2.0 (2026-02-10)

### 🎉 New Features
- Voice cloning using Fish Audio API (#123)
- Story generation with Gemini AI (#124)

### 🐛 Bug Fixes
- Fix 401 error in Edge Functions (#125)
- Resolve navigation issue in story detail page (#126)

### 🔧 Improvements
- Optimize story loading performance (#127)
- Update dependencies (#128)

### ⚠️ Breaking Changes
- None

### 📝 Migration Guide
- Run migration 007 for voice_profiles table
```

---

## 6. Hotfix 流程

### 6.1 緊急修復步驟

```bash
# 1. 從 main 創建 hotfix branch
git checkout main
git pull origin main
git checkout -b hotfix/critical-issue

# 2. 修復問題
# ... make changes ...

# 3. 提交
git add .
git commit -m "fix(critical): resolve production issue

[Description of the fix]"

# 4. 創建 PR (標記為 urgent)
# PR title: hotfix: [description]

# 5. 快速 review 並合併

# 6. 立即部署
```

### 6.2 Hotfix 規則

- 只修復緊急的生產問題
- 最小化變更範圍
- 需要立即 review 和合併
- 部署後需要監控

---

## 7. Code Review 規範

### 7.1 Review Checklist

**功能性**
- [ ] 程式碼實現了預期功能
- [ ] 邊界情況有處理
- [ ] 錯誤處理完整

**程式碼品質**
- [ ] 遵循 coding-style 規範
- [ ] 沒有重複程式碼
- [ ] 命名清晰易懂
- [ ] 複雜邏輯有註釋

**安全性**
- [ ] 沒有硬編碼 secrets
- [ ] 輸入有驗證
- [ ] 使用 x-user-id workaround (Edge Functions)

**測試**
- [ ] 有對應的測試
- [ ] 測試覆蓋關鍵路徑

### 7.2 Review 回應規範

| 標記 | 意義 | 處理方式 |
|------|------|---------|
| `LGTM` | Looks Good To Me | 可以合併 |
| `nit:` | Nitpick | 小建議，可選修改 |
| `suggestion:` | 建議 | 建議修改 |
| `question:` | 疑問 | 需要解釋 |
| `blocker:` | 阻擋 | 必須修改才能合併 |

---

## 8. Git Hooks (推薦)

### 8.1 pre-commit

```bash
#!/bin/sh
# .git/hooks/pre-commit

# Run Flutter analyze
cd app && flutter analyze --no-fatal-infos

# Check for console.log / print statements
if git diff --cached | grep -E "(console\.log|print\()" > /dev/null; then
  echo "Warning: Found console.log or print statements"
  exit 1
fi
```

### 8.2 commit-msg

```bash
#!/bin/sh
# .git/hooks/commit-msg

# Validate conventional commit format
commit_regex='^(feat|fix|docs|style|refactor|perf|test|chore|ci)(\([a-z]+\))?: .{1,72}$'

if ! grep -qE "$commit_regex" "$1"; then
  echo "Invalid commit message format."
  echo "Use: <type>(<scope>): <subject>"
  echo "Types: feat, fix, docs, style, refactor, perf, test, chore, ci"
  exit 1
fi
```

---

## 9. 常用 Git 命令

```bash
# 查看狀態
git status

# 查看最近提交
git log --oneline -10

# 創建並切換 branch
git checkout -b feature/new-feature

# 同步 main
git fetch origin
git rebase origin/main

# 修改最後一個 commit (未 push)
git commit --amend

# 撤銷最後一個 commit (保留變更)
git reset --soft HEAD~1

# 暫存變更
git stash
git stash pop

# 查看 diff
git diff                    # 未 staged
git diff --staged           # 已 staged
git diff main..feature/xxx  # 與 main 比較
```

---

## Checklist

- [ ] Branch 名稱遵循規範
- [ ] Commit message 使用 Conventional Commits
- [ ] PR 有清晰的描述和 checklist
- [ ] Code review 完成
- [ ] CI 測試通過
- [ ] 合併使用 Squash and Merge
