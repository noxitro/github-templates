# Security Policy

## 脆弱性の報告

公開 Issue には書かないでください。GitHub の **Security → Report a vulnerability**
(Private vulnerability reporting) から報告をお願いします。

このリポジトリの git-hooks と共通ワークフローは、各リポジトリへ秘密情報が入るのを防ぐためのものです。
検査をすり抜けるパターン (検出漏れ) を見つけた場合も、同じ経路で報告してください。

## リポジトリ側の対策

| 対策 | 仕組み |
|---|---|
| 秘密情報の混入防止 | `self-check.yml` から共通の `secret-scan.yml` を、変更した版のまま動かす。GitHub の Secret scanning / Push protection も有効 |
| ワークフローの誤り | `self-check.yml` から `workflow-lint.yml` (actionlint / ruff) |
| 依存の更新 | Dependabot (`.github/dependabot.yml`、GitHub Actions) |
| 既定ブランチの保護 | `rulesets/protect-default-branch.json` (PR 必須・force-push と削除の禁止・必須チェック) |
