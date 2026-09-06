---
name: ci-fix-failing-tests
description: "CI で失敗したテストを修正するためのガイド。CI失敗の原因が特定された後、自動修正を試みる場合に使用します。"
allowed-tools: ["Read", "Edit", "Bash"]
---

# CI Fix Failing Tests

CI で失敗したテストを修正するスキル。
テストコードの修正、または本体コードの修正を行います。

---

## 入力

- **失敗テスト情報**: テスト名、エラーメッセージ
- **テストファイル**: 失敗したテストのソース
- **テスト対象コード**: テスト対象の実装

元の要求、対象 branch/commit、失敗ログ、既存 spec から不足情報を先に回収する。修正依頼の担当範囲と DoD、必須検証、承認元を維持する。原因分析だけの依頼は読み取り専用で終える。既存テストや保護された設定を変える場合は、適用される承認 gate と元の承認を照合し、必要な操作だけを保留する。

---

## 出力

- **修正されたコード**: テストまたは実装の修正
- **テスト通過の確認**

---

## 実行手順

### Step 1: 失敗テストの特定

```bash
# ローカルでテスト実行
npm test 2>&1 | tail -50

# 特定ファイルのテスト
npm test -- {{test-file}}
```

### Step 2: エラータイプの分類

#### タイプ A: アサーション失敗

```
Expected: "expected value"
Received: "actual value"
```

→ 実装が期待と異なる、またはテストの期待値が間違っている

#### タイプ B: タイムアウト

```
Timeout - Async callback was not invoked within the 5000ms timeout
```

→ 非同期処理が完了しない、または時間がかかりすぎる

#### タイプ C: 型エラー

```
TypeError: Cannot read properties of undefined
```

→ null/undefined のアクセス、または初期化の問題

#### タイプ D: モック関連

```
expected mockFn to have been called
```

→ モックの設定不足、または呼び出しが行われていない

### Step 3: 修正戦略の決定

```markdown
## 修正方針判断

1. **テストが正しい場合** → 実装を修正
2. **既存 spec または承認済み要件からテストの誤りを確認できた場合** → 適用される承認 gate に従ってテストを修正
3. **両方修正が必要**   → 実装を優先

判断基準:
- 仕様・要件に照らしてどちらが正しいか
- 最近の変更は何か
- 他のテストへの影響
```

### Step 4: 修正の実装

#### アサーション失敗の修正

```typescript
// テストの期待値が間違っている場合
it('calculates correctly', () => {
  // 修正前
  expect(calculate(2, 3)).toBe(5)
  // 修正後（仕様が掛け算の場合）
  expect(calculate(2, 3)).toBe(6)
})

// 実装が間違っている場合
// → 実装ファイルを修正
```

#### タイムアウトの修正

非同期処理の欠陥と実行環境の制約を先に切り分ける。待機時間の変更は、仕様上の許容時間と計測結果が根拠になる場合だけ行う。失敗を隠す目的で延長しない。

```typescript
// タイムアウトを延長
it('fetches data', async () => {
  // ...
}, 10000)  // 10秒に延長

// または async/await を正しく使用
it('fetches data', async () => {
  await waitFor(() => {
    expect(screen.getByText('Data')).toBeInTheDocument()
  })
})
```

#### モック関連の修正

```typescript
// モックの設定を追加
vi.mock('../api', () => ({
  fetchData: vi.fn().mockResolvedValue({ data: 'mock' })
}))

// beforeEach でリセット
beforeEach(() => {
  vi.clearAllMocks()
})
```

### Step 5: 修正後の確認

元の失敗が解消したことと、必要な既存検証を確認する。以下の必須確認が通った後は、コード変更、新しい証拠、未解消の懸念がある場合だけ再実行や対象の追加を行う。

```bash
# 失敗テストを再実行
npm test -- {{test-file}}

# 全テスト実行（リグレッション確認）
npm test
```

---

## 修正パターン集

### スナップショット更新

承認済みの仕様変更と実際の差分を照合してから更新する。現在の実装に合わせるだけの期待値更新は行わない。

```bash
# スナップショットの更新
npm test -- -u

# 特定テストのみ
npm test -- {{test-file}} -u
```

### 非同期テストの修正

```typescript
// findBy を使用（自動待機）
const element = await screen.findByText('Text')

// waitFor を使用
await waitFor(() => {
  expect(mockFn).toHaveBeenCalled()
})
```

### モックデータの更新

```typescript
// 実装の変更に合わせてモックを更新
const mockData = {
  id: 1,
  name: 'Test',
  createdAt: new Date().toISOString()  // 新しいフィールド
}
```

---

## 修正後のチェックリスト

- [ ] 失敗していたテストが通過する
- [ ] 他のテストが壊れていない
- [ ] 実装の意図と一致している
- [ ] 過度に緩いテストになっていない

---

## 完了報告フォーマット

```markdown
## ✅ テスト修正完了

### 修正内容

| テスト | 問題 | 修正 |
|-------|------|------|
| `{{テスト名}}` | {{問題}} | {{修正内容}} |

### 確認結果

```
Tests: {{passed}} passed, {{total}} total
```

### 次のアクション

{{既に承認済みで残っている作業、または未承認の操作と必要な判断。その契約と根拠。残件がなければ省略}}
```

---

## 注意事項

- **テストを削除して成功にしない**: 必要な検証を残す
- **skip で成功にしない**: 一時的な skip もテスト失敗の解決にしない
- **ルートコーズを特定**: 表面的な修正を避ける
