# github-templates

個人開発のリポジトリで使い回す GitHub 設定のテンプレート置き場。

ここに置いたファイルは保管用で、GitHub が自動で読んで適用することはない。
使うときは各リポジトリの画面から取り込む。

## 中身

| パス | 内容 |
|---|---|
| `rulesets/protect-default-branch.json` | 既定ブランチ (`main` など) を守るルールセット |
| `.github/workflows/apply-ruleset.yml` | 上のテンプレートを指定リポジトリへ取り込む Actions |
| `agent-rules/rules.md` | AI エージェント (Claude Code・GitHub Copilot・opencode) 向けのルール。PR などを原則日本語で書く |
| `.github/workflows/apply-agent-rules.yml` | 上のルールを指定リポジトリへ PR で配る Actions |
| `scripts/apply_agent_rules.py` | ルールをリポジトリのファイルに入れる処理 (Actions から使う。手元でも動く) |

## ブラウザだけで取り込む (Actions)

### 最初に 1 回だけ: トークンを登録

GitHub Actions の標準トークンではほかのリポジトリの設定を変えられないので、専用のトークンを作る。

1. **Settings (自分のアカウント) → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**
   - Repository access: **All repositories**
   - Permissions → Repository permissions → **Administration: Read and write**
   - エージェントのルールも配るなら、さらに **Contents: Read and write** と **Pull requests: Read and write**
   - 有効期限は好みで。切れたら作り直して Secret を差し替える
2. このリポジトリの **Settings → Secrets and variables → Actions → New repository secret**
   - Name: `RULESET_TOKEN`
   - Secret: 1 で作ったトークン

### 取り込むたびに

1. このリポジトリの **Actions → ルールセットを適用 → Run workflow**
2. 入力して実行
   - `repo`: 対象のリポジトリ名 (例: `nox-apk-manager`)。`all` なら全リポジトリ (フォークとアーカイブ済みは除く)
   - `required_check`: CI の必須チェック名 (例: `単体テストとビルド`)。空なら付けない。`all` のときは空にする

同じ名前のルールセットが既にあれば上書きするので、テンプレートを直したあとに流し直せば全リポジトリへ反映できる。

## rulesets/protect-default-branch.json

個人開発 (自分と AI だけが触る) 向けの最小限の保護。

| ルール | 設定 | 理由 |
|---|---|---|
| 対象 | `~DEFAULT_BRANCH` | `main` でも `master` でもそのまま効く |
| ブランチ削除 | 禁止 | 誤削除を防ぐ |
| force-push | 禁止 | 履歴の書き換えを防ぐ |
| PR 必須 | ON、承認数 0 | 直接 push を防ぐ。承認を 1 以上にすると自分の PR を自分で承認できず詰まる |
| 回避できる人 | リポジトリ管理者 (`actor_id: 5`) | 緊急時に自分だけは回避できる |

### 画面から手で取り込む場合

1. 対象リポジトリの **Settings → Rules → Rulesets**
2. **New ruleset ▾ → Import a ruleset** でこの JSON を選ぶ
3. 内容を確認して **Create**

非公開リポジトリの場合、GitHub Free プランではルールセットが効かない (公開にするか Pro が必要)。

### CI の必須チェックを足す

CI のジョブ名はリポジトリごとに違うので、テンプレートには入れていない。
取り込んだあと、ルールセットの編集画面で追加する。

1. **Require status checks to pass** を ON
2. **Add checks** で CI のジョブ名を選ぶ (例: `単体テストとビルド`)

一度も CI が走っていないとジョブ名が候補に出ない。先に PR か push で CI を 1 回走らせておく。
存在しないジョブ名を指定すると、チェックが永遠に来ずマージできなくなるので注意。

## agent-rules/rules.md (AI エージェント向けのルール)

PR・コミットメッセージ・レビューのコメントなど、人が読む文章を原則日本語で書くルール。
ツールごとに読むファイルが違うので、配るときは次の 3 つに入れる。

| ファイル | 読むツール | 入れ方 |
|---|---|---|
| `AGENTS.md` | opencode など | 目印のコメントで囲んだ部分だけを入れるか差し替える |
| `.github/copilot-instructions.md` | GitHub Copilot (チャット・コードレビュー・コーディングエージェント) | 同上 (Copilot はほかのファイルを読み込めないので写しを置く) |
| `CLAUDE.md` | Claude Code | `@AGENTS.md` (AGENTS.md を読み込む行) がなければ先頭に足す |

目印の外はそのまま残すので、リポジトリ独自のルールは目印の外に書く。
ルールを変えるときは `agent-rules/rules.md` を直して、もう一度配る。

### 配る (Actions)

1. トークンに Contents と Pull requests の権限を付けておく (上の「トークンを登録」)
2. このリポジトリの **Actions → エージェントのルールを配る → Run workflow**
3. `repo` に対象のリポジトリ名を入れて実行。`all` なら全リポジトリ (フォーク・アーカイブ済み・空のリポジトリは除く)

変更があるリポジトリには、ブランチ `agent-rules` から PR ができる。既定ブランチは PR 必須なので、各リポジトリで PR をマージする。
PR が開いたまま流し直すと、その PR が更新される。

手元で入れるなら `python3 scripts/apply_agent_rules.py <リポジトリのディレクトリ>`。

### リポジトリの外 (個人の設定)

リポジトリに置いたルールは、そのリポジトリの中でしか効かない。どのリポジトリでも効かせたいときは、各ツールの個人の設定にも同じ内容を書く。

| ツール | 場所 |
|---|---|
| Claude Code (手元) | `~/.claude/CLAUDE.md` |
| Claude Code (クラウド) | 環境の設定の Setup script で `~/.claude/CLAUDE.md` を作る |
| opencode | `~/.config/opencode/AGENTS.md` (なければ `~/.claude/CLAUDE.md` を読む) |
| GitHub Copilot (github.com のチャット) | Copilot の設定の Personal instructions |
| GitHub Copilot (VS Code) | ユーザー設定の `github.copilot.chat.*.instructions` (コミットメッセージと PR の説明は別の設定) |

GitHub 上で動く Copilot のコードレビューとコーディングエージェントは個人の設定を読まないので、リポジトリに配っておく。
