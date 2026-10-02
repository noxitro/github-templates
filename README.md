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
| `templates/` | 各リポジトリに置く薄い設定 (共通ワークフローの呼び出しと、クラウドのセッションでフックを入れる設定) |

## ブラウザだけで取り込む (Actions)

### 最初に 1 回だけ: トークンを登録

GitHub Actions の標準トークンではほかのリポジトリの設定を変えられないので、専用のトークンを作る。

1. **Settings (自分のアカウント) → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**
   - Repository access: **All repositories**
   - Permissions → Repository permissions → **Administration: Read and write**
   - 有効期限は好みで。切れたら作り直して Secret を差し替える
2. このリポジトリの **Settings → Secrets and variables → Actions → New repository secret**
   - Name: `RULESET_TOKEN`
   - Secret: 1 で作ったトークン

### 取り込むたびに

1. このリポジトリの **Actions → ルールセットを適用 → Run workflow**
2. 入力して実行
   - `repo`: 対象のリポジトリ名 (例: `nox-apk-manager`)。`all` なら全リポジトリ (フォークとアーカイブ済みは除く)
   - `required_check`: CI の必須チェック名。カンマ区切りで複数可 (例: `単体テストとビルド, Lint`)。空なら付けない。`all` のときは空にする

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

## git-hooks (秘密情報・個人情報の検査)

`git-hooks/` のフックを global の `core.hooksPath` で全リポジトリに当てる。
フックの本体はここにしか無いので、直せば全リポジトリに効く。

| 段階 | 検査 |
|---|---|
| pre-commit | user.email が noreply か / ステージした内容 (`scan.sh` と gitleaks) |
| commit-msg | コミットメッセージに外部資料の名前が無いか |
| pre-push | push する範囲のファイル・コミットメッセージ・作成者とコミッターのメールアドレス・gitleaks |

`scan.sh` が見るもの: 秘密情報 (鍵・トークン・接続文字列・Discord の Webhook URL)、
個人情報 (ローカル絶対パス・個人メール・このマシンのユーザー名とホスト名)、
ビルド生成物の混入、MIT と両立しないライセンス・他者の著作権表示、非公開 SDK の識別子、
外部資料の名前 (`external-names.sha256` にハッシュで置く) と手元の非公開リスト
(`~/.config/nox/private-names.sha256`、リポジトリには置かない)。

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
| `.claude/settings.json`、`.claude/hooks/session-start.sh` | Claude Code on the web のセッション開始時に、このリポジトリを clone してフックと gitleaks を入れる |

リポジトリ固有の除外は、各リポジトリのルートに置く。

- `.githooks-allow`: `scan.sh` の検査から外すパス (1 行 1 パス、完全一致)。理由をコメントで残す。
- `.gitleaks.toml`: gitleaks の設定。無ければ `git-hooks/gitleaks.toml` を使う。置くときは共通側を写して allowlist を足す。

### 外部資料の名前を足す

```sh
python3 ~/.config/nox/github-templates/git-hooks/check-external-names.py --hash '<名前>'
```

出力を `git-hooks/external-names.sha256` に追記する (全リポジトリに効く)。
公開リポジトリにハッシュでも置きたくない名前は `--add-private` で手元の非公開リストへ入れる。

### gitleaks の版を上げる

`git-hooks/install-gitleaks.sh` の `GITLEAKS_VERSION` と `GITLEAKS_SHA256_*` だけを直す
(SHA256 はリリースの checksums.txt から写す)。CI とクラウドのセッションは両方ここから入れる。
