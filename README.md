# github-templates

個人開発のリポジトリで使い回す GitHub 設定のテンプレート置き場。

ここに置いたファイルは保管用で、GitHub が自動で読んで適用することはない。
使うときは各リポジトリの画面から取り込む。

## 中身

| パス | 内容 |
|---|---|
| `rulesets/protect-default-branch.json` | 既定ブランチ (`main` など) を守るルールセット |
| `.github/workflows/apply-ruleset.yml` | 上のテンプレートを指定リポジトリへ取り込む Actions |
| `git-hooks/` | 公開してはいけないものを commit / push の前に止める git フック (全リポジトリ共通) |
| `.github/workflows/secret-scan.yml` | 同じ検査を CI で行う共通ワークフロー (各リポジトリから呼ぶ) |
| `.github/workflows/file-format.yml` | BOM と改行コードの事故 (一括変換・混在・BOM の付け外し) を拾う共通ワークフロー |
| `.github/workflows/workflow-lint.yml` | ワークフローの静的検査 (actionlint) と Python スクリプトの ruff の共通ワークフロー |
| `.github/workflows/dependency-review.yml` | PR で増える依存の脆弱性とライセンスを検査する共通ワークフロー |
| `.github/workflows/claude-agent.yml` | PR / Issue のコメント (`/claude ...`) で Claude にレビューや質問をさせる共通ワークフロー |
| `.github/workflows/self-check.yml` | このリポジトリ自身の検査 (共通ワークフローを変更した版のまま動かす) |
| `scripts/file-format/` | `file-format.yml` の検査本体と、BOM を外す `strip-bom.py` |
| `scripts/discord_webhook.py` | 共通ワークフローから失敗を Discord に流す |
| `templates/` | 各リポジトリに置く薄い設定 (共通ワークフローの呼び出し・Dependabot・SECURITY.md・PR テンプレートなど) |

## ブラウザだけで取り込む (Actions)

### 最初に 1 回だけ: トークンを登録

GitHub Actions の標準トークンではほかのリポジトリの設定を変えられないので、専用のトークンを作る。

1. **Settings (自分のアカウント) → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**
   - Repository access: **All repositories**
   - Permissions → Repository permissions → **Administration: Read and write**
   - 有効期限は好みで。切れたら作り直して Secret を差し替える
2. このリポジトリの **Settings → Environments → New environment**
   - Name: `rulesets`
   - **Deployment branches and tags** を **Selected branches and tags** にし、ブランチ `main` だけを許可する
3. 2 で作った Environment の **Environment secrets → Add environment secret**
   - Name: `RULESET_TOKEN`
   - Secret: 1 で作ったトークン
4. このリポジトリ自身にも `protect-default-branch` を取り込む (下の「取り込むたびに」で `repo` を `github-templates` にする)

トークンはリポジトリの Secret (Secrets and variables → Actions) には置かない。
リポジトリに書き込める者は、そのリポジトリの Secret を workflow から使える。
作業ブランチに workflow を置くだけで、全リポジトリのルールセットを書き換えられるこのトークンに届いてしまう。
`main` からしか使えない Environment に置き、`main` を 4 で PR 必須にしておけば、PR を通さずには届かない。
以前リポジトリの Secret として登録していた場合は、Environment に登録し直してから消す。

### 取り込むたびに

1. このリポジトリの **Actions → ルールセットを適用 → Run workflow** (ブランチは `main` のまま)
2. 入力して実行
   - `repo`: 対象のリポジトリ名 (例: `nox-apk-manager`)。`all` なら全公開リポジトリ (フォーク・アーカイブ済み・非公開は除く。非公開は GitHub Free だとルールセットを使えない)
   - `required_check`: CI の必須チェック名。カンマ区切りで複数可 (例: `単体テストとビルド, Lint`)。空なら付けない。`all` のときは空にする

同じ名前のルールセットが既にあれば上書きするので、テンプレートを直したあとに流し直せば全リポジトリへ反映できる。

## rulesets/protect-default-branch.json

個人開発 (自分と AI だけが触る) 向けの最小限の保護。

| ルール | 設定 | 理由 |
|---|---|---|
| 対象 | `~DEFAULT_BRANCH` | `main` でも `master` でもそのまま効く |
| ブランチ削除 | 禁止 | 誤削除を防ぐ |
| force-push | 禁止 | 履歴の書き換えを防ぐ |
| PR 必須 | ON、承認数 0 | 直接 push を防ぐ。変更は必ず PR と CI を通す |
| 必須チェック | リポジトリごとに足す | 作者が人でも AI でも、CI と Secret scan が通らないと入らない (下の「CI の必須チェックを足す」) |
| 回避できる人 | リポジトリ管理者 (`actor_id: 5`) | 緊急時に自分だけは回避できる |

承認数を 0 にしているのは、個人開発では承認できる別の人がいないため。
PR を作った本人は自分の PR を承認できず、クラウドのセッションのように自分のアカウントで動く AI の PR も
作成者が自分になるので、承認必須にしても誰も承認できず、毎回管理者の回避でマージすることになる。
その AI は管理者として回避もできるので、承認必須にしても AI のマージは止まらない。

AI に勝手にマージさせないことは、ルールではなく運用で守る (AI は PR を作るまで、マージは自分が判断する。
各リポジトリの AGENTS.md / CLAUDE.md に書いておく)。共同作業者が加わったときや、自分とは別の身元
(GitHub App など) で動く AI に PR 作成まで任せるときは、承認数を 1 に戻す。

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

## git-hooks (秘密情報・個人情報の検査)

`git-hooks/` のフックを global の `core.hooksPath` で全リポジトリに当てる。
フックの本体はここにしか無いので、直せば全リポジトリに効く。

| 段階 | 検査 |
|---|---|
| pre-commit | user.email が noreply か / ステージした内容 (`scan.sh` と gitleaks) / 改行の混在と BOM を直す (`fix-format.py`、止めない) |
| commit-msg | コミットメッセージに外部資料の名前・所属組織の文脈を示す語が無いか |
| pre-push | push する範囲のファイル・コミットメッセージ・作成者とコミッターのメールアドレス・gitleaks |

`scan.sh` が見るもの: 秘密情報 (鍵・トークン・接続文字列・Discord の Webhook URL)、
個人情報 (ローカル絶対パス・個人メール・このマシンのユーザー名とホスト名)、
ビルド生成物の混入、MIT と両立しないライセンス・他者の著作権表示、非公開 SDK の識別子、
外部資料の名前 (`external-names.sha256` にハッシュで置く) と手元の非公開リスト
(`~/.config/nox/private-names.sha256`、リポジトリには置かない)、
所属組織の文脈を示す語 (`org-context-terms.txt`、平文)。

最後のものは、名前を伏せていても「組織内での取り組み」「誰が推進して、どこへ配ったか」と
読み取れる書き方を止めるための層。照合は語の一覧なので、経緯や体制を一般語だけで書いた文は
すり抜ける。公開前には人 (またはエージェント) が「同じ組織の人が読んで書き手や対象の
プロジェクトを推測できないか」を確かめる前提で、この検査はその取りこぼしを拾う。
手元だけで足したい語は `~/.config/nox/private-terms.txt` (1 行 1 語) に書く。
誤検出はリポジトリの `.githooks-allow` でパスごとに外す。

### 改行コードと BOM の自動修正 (pre-commit)

`fix-format.py` が、ステージした内容の次の事故をコミットの前に直す。コミットは止めない
(直せないものは知らせるだけ)。直したファイルはメッセージで知らせる。

- 改行の混在 (1 本のファイルに CRLF と LF が混ざったもの): HEAD の形式に揃える。
  HEAD に無い新しいファイルは、多い方に揃える。
- BOM: リポジトリに `.github/scripts/bom_policy.py` があればその決まりに合わせる。
  無ければ、HEAD で BOM の無かったファイルに付いた BOM だけを外す。

ファイル全体の CRLF <-> LF の変換は、意図した変換と区別できないので直さずに知らせるだけ。
`.gitattributes` で git が改行を正規化するファイル (`text` / `text=auto`) とバイナリは触らない。
作業ツリーは、ステージと同じ中身のときだけ直す (`git add -p` で一部だけステージしたファイルは触らない)。
`git commit <パス>` では、コミットと作業ツリーは直るが、ステージに直す前の内容が残る
(git がコミットの間ステージをロックしているため)。`git add <パス>` で揃う。

```sh
git config nox.fixFormat false     # このリポジトリでは直さない
NOX_FIX_FORMAT=0 git commit ...    # このコミットだけ直さない
```

### 対象のリポジトリ

既定では `origin` (pre-push では push 先) が `noxitro/` のリポジトリだけを検査する
(他者のリポジトリを clone してコミットしたときに、GPL や他者の著作権表示で止めないため)。
リポジトリごとに変えられる:

```sh
git config nox.hooks true    # remote が無いリポジトリなどでも検査する
git config nox.hooks false   # このリポジトリでは検査しない
```

リポジトリごとの `core.hooksPath` (husky などのフック管理) は global より優先されるので、
それを使っているリポジトリでは共通のフックは走らない。

global の `core.hooksPath` を設定すると、git は `.git/hooks` を見なくなる。そのため共通のフックは、
検査が通ったあと (対象外のリポジトリでは検査なしで) `.git/hooks/<名前>` があれば続けて呼ぶ
(pre-commit / commit-msg / pre-push と、Git LFS が使う post-checkout / post-commit / post-merge。`chain.sh`)。
Git LFS のフックは `git lfs install` だと共通のフックとぶつかって入らないので、
LFS を使うリポジトリの中で次のように `.git/hooks` へ入れる。

```sh
git -c core.hooksPath=.git/hooks lfs install --local
```

### 手元で有効にする (マシンごとに 1 回)

```sh
git clone https://github.com/noxitro/github-templates ~/.config/nox/github-templates
sh ~/.config/nox/github-templates/git-hooks/install.sh
```

更新は `git -C ~/.config/nox/github-templates pull` だけでよい。
gitleaks は Windows なら `winget install Gitleaks.Gitleaks` で入れる (無ければ警告を出して組み込みパターンだけで検査する)。

旧方式 (リポジトリの `tools/git-hooks` を `core.hooksPath` に設定) のリポジトリでは、
その中で `install.sh` を実行すると古い設定を外す。外さないと global より優先され、
`tools/git-hooks` を消したあとはフックが黙って走らなくなる。

### 各リポジトリに置くもの (`templates/`)

| パス | 役目 |
|---|---|
| `.github/workflows/secret-scan.yml` | 共通の Secret scan を呼ぶ。必須チェックにするときのジョブ名は `scan / Scan` |
| `.github/workflows/file-format.yml` | 共通の File format を呼ぶ (下の「ファイル形式の検査」)。ジョブ名は `check / BOM / line endings` |
| `.github/workflows/workflow-lint.yml` | 共通の Workflow lint を呼ぶ。ジョブ名は `lint / Workflow lint` |
| `.github/workflows/dependency-review.yml` | 共通の Dependency review を呼ぶ。依存のマニフェストがある公開リポジトリだけ |
| `.github/workflows/claude.yml` | 共通の Claude を呼ぶ (下の「Claude」) |
| `.github/dependabot.yml` | Dependabot の更新対象。GitHub Actions は全リポジトリ、ほかは使うエコシステムだけ残す |
| `.github/scripts/bom_policy.py` | BOM の決まりを変えるときだけ置く (既定は `*.ps1` / `*.psm1` / `*.psd1` だけ BOM 必須) |
| `.github/PULL_REQUEST_TEMPLATE.md` | PR の確認項目。リポジトリのテストのコマンドに直す |
| `.editorconfig` | 文字コードの既定 (`bom_policy.py` と揃える)。改行コードは決めない |
| `SECURITY.md` | 脆弱性の報告先 (Private vulnerability reporting)。使っている対策だけ表に残す |
| `AGENTS.snippet.md` | 各リポジトリの AGENTS.md / CLAUDE.md に写す共通の決まり (AI はマージしない、など) |
| `.claude/settings.json`、`.claude/hooks/session-start.sh` | Claude Code on the web のセッション開始時に、このリポジトリを clone してフックと gitleaks を入れる |

リポジトリ固有の除外は、各リポジトリのルートに置く。

- `.githooks-allow`: `scan.sh` の検査から外すパス (1 行 1 パス、完全一致)。理由をコメントで残す。
- `.gitleaks.toml`: gitleaks の設定。無ければ `git-hooks/gitleaks.toml` を使う。置くときは共通側を写して allowlist を足す。
- `.gitleaksignore`: gitleaks の誤検知を 1 件ずつ外す (ルールは緩めない)。行は gitleaks が出す
  Finding の fingerprint (`<コミット>:<パス>:<ルール>:<行>`)。上に理由をコメントで残す。

```text
# ServiceAccountAuthTest は鍵をテストの中で生成し、PEM の見出しを文字列で付けているだけ
<コミット>:app/src/test/.../ServiceAccountAuthTest.kt:private-key:34
```

### 新しいリポジトリの初期設定

`templates/` の中から使うものを写したうえで、リポジトリの設定を揃える。

1. **Settings → Code security**: Dependabot alerts / security updates、Secret scanning と Push protection、
   Private vulnerability reporting を有効にする (公開リポジトリならすべて無料)。
2. ルールセットを取り込む (上の「取り込むたびに」)。必須チェックには `scan / Scan` と CI のジョブ名を入れる。
3. MIT などの `LICENSE` を置く (`scan.sh` のライセンス検査は MIT と両立するかを見る)。

CodeQL は言語ごとに設定が違うので共通にしていない。**Settings → Code security → Code scanning →
Set up → Default** で足りる。ビルド手順を変えたい (C++ / C# / Kotlin など) ときだけ
`github/codeql-action` の `init` / `analyze` を使うワークフローを各リポジトリに置く。

## ファイル形式の検査

`.github/workflows/file-format.yml` (本体は `scripts/file-format/check-file-format.py`) が、
書き換えツールが BOM を剥がす・ファイル全体の改行を一括変換する・CRLF のファイルに LF の行を
混ぜる、といった事故を CI で拾う。pre-commit の `fix-format.py` が手元で直すものの取りこぼしを止める層。

- 比べる範囲: 作業ブランチは既定ブランチとの分岐点から、既定ブランチは push の前後。
  作業ブランチで事故を直すコミットを足せば、累積では相殺されて通る。
- 改行: ファイルごとに元の形式 (CRLF / LF) を保っているかを見る。新しいファイルは混在だけを見る。
- BOM: `.github/scripts/bom_policy.py` があればその決まり、無ければ `scripts/file-format/bom_policy.py`。
- 意図して変換するときは、コミットメッセージに `Format-Change: <パス or glob>` の行を書く。
- 失敗を Discord に流すときは、Secret `DISCORD_WEBHOOK_URL` を作って呼び出し側の `secrets:` で渡す。

手元で確かめる・BOM を外す:

```sh
T=~/.config/nox/github-templates
python3 $T/scripts/file-format/check-file-format.py --base origin/main   # main との分岐点から比べる
python3 $T/scripts/file-format/strip-bom.py <パス>...                     # 決まりに反する BOM を外す
```

## ワークフローの静的検査

`.github/workflows/workflow-lint.yml` が actionlint (式の型・未定義の入力・`run:` の shellcheck) と、
`python-paths` で指定したパスの ruff (構文エラーと未定義名だけ) を走らせる。
版を上げるときは、ファイル先頭の `env` の版と SHA256 だけを直す (SHA256 は actionlint のリリースの checksums.txt から写す)。

## 依存の検査 (Dependabot / Dependency review)

`templates/.github/dependabot.yml` は GitHub Actions の更新を全リポジトリで週 1 回、同じ action の更新を
1 本の PR にまとめる。npm / NuGet / Gradle などは使うものだけコメントを外す
(minor と patch はまとめ、major は挙動が変わりうるので個別の PR に残す)。

`.github/workflows/dependency-review.yml` は PR で増える依存に、既定で moderate 以上の脆弱性か
GPL / LGPL / AGPL のライセンスがあれば失敗させる (`git-hooks/scan.sh` のライセンス検査と同じ考え)。
`fail-on-severity` と `deny-licenses` で変えられる。

## AI エージェントの決まり

`templates/AGENTS.snippet.md` を各リポジトリの AGENTS.md / CLAUDE.md に写す。
要点は、AI は作業ブランチで PR を作るまでで、既定ブランチへのマージはユーザーが行うこと
(「進めて」「全部やって」はマージの許可ではない)。ルールセットは承認数 0 なので、
ユーザーの身元で動く AI のマージは仕組みでは止まらず、この決まりで止める。

### 外部資料の名前を足す

```sh
python3 ~/.config/nox/github-templates/git-hooks/check-external-names.py --hash '<名前>'
```

出力を `git-hooks/external-names.sha256` に追記する (全リポジトリに効く)。
公開リポジトリにハッシュでも置きたくない名前は `--add-private` で手元の非公開リストへ入れる。

### gitleaks の版を上げる

`git-hooks/install-gitleaks.sh` の `GITLEAKS_VERSION` と `GITLEAKS_SHA256_*` だけを直す
(SHA256 はリリースの checksums.txt から写す)。CI とクラウドのセッションは両方ここから入れる。

## Claude (コメントでレビューを頼む)

PR / Issue のコメントの先頭に `/claude` と書き、空白か改行を挟んで頼むと、Claude が差分をレビューしたり質問に答えたりする
(例: `/claude レビューして`)。本体は `.github/workflows/claude-agent.yml` で、各リポジトリには呼び出し側だけを置く。

### リポジトリに入れる

1. `templates/.github/workflows/claude.yml` を同じパスに置く。
   - issue_comment で起動するワークフローは既定ブランチの版が使われるので、既定ブランチに入ってから効く。
2. リポジトリの **Settings → Secrets and variables → Actions** に Secret を登録する。
   - `CLAUDE_CODE_OAUTH_TOKEN` (必須): 手元で `claude setup-token` を実行して得たもの。
     Claude のサブスクリプションの利用枠を使う。
   - `AGENT_APP_ID` / `AGENT_APP_PRIVATE_KEY` (任意): 自前の GitHub App の App ID と秘密鍵。
     両方あるとその App のトークンで動き、コメントや push がその App の名義になる。無ければ Claude GitHub App で動く。
     App には Contents / Pull requests / Issues の Read and write を与え、対象のリポジトリにインストールしておく。
3. Claude GitHub App (自前の App を使わない場合) が対象のリポジトリにインストールされていることを確かめる。

反応するのはオーナー・メンバー・共同編集者のコメントだけ (公開リポジトリで他人に利用枠を使われないため)。

### 合図を変える

呼び出し側で `trigger-phrase` を渡す。自前の App の名前にすると `@<App の名前> レビューして` で動く
(GitHub のメンション通知が飛ぶわけではなく、コメントの先頭の文字列で判定している)。

```yaml
    uses: noxitro/github-templates/.github/workflows/claude-agent.yml@main
    with:
      trigger-phrase: "@<App の名前>"
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
      AGENT_APP_ID: ${{ secrets.AGENT_APP_ID }}
      AGENT_APP_PRIVATE_KEY: ${{ secrets.AGENT_APP_PRIVATE_KEY }}
```
