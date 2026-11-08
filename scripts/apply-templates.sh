#!/bin/bash
# templates/ の雛形を対象のリポジトリへ PR で入れる。.github/workflows/apply-templates.yml から呼ぶ。
# 手元でも DRY_RUN=1 で試せる (gh でログイン済みなら、push も PR もせずに何をするかだけ出す)。
#
# 環境変数:
#   OWNER      リポジトリの持ち主
#   REPOS      対象のリポジトリ名。カンマか空白で区切って複数可。
#              all なら持ち主の全リポジトリ (フォーク・アーカイブ済み・このリポジトリ自身を除く)
#   SETS       入れる雛形の組。カンマ区切りで secret-scan / claude / session-start
#   OVERWRITE  true なら、雛形と中身の違う既存ファイルも上書きする。
#              .claude/settings.json はほかの設定も入るファイルなので、true でも上書きしない
#   DRY_RUN    1 なら push も PR もしない
#   GH_TOKEN   対象のリポジトリの Contents / Pull requests / Workflows に書けるトークン
#              (手元の DRY_RUN では gh のログインで足りる)
#
# 何度流しても同じ結果になる。PR のブランチ (templates/apply) は毎回既定ブランチから作り直して
# force-push するので、開いている PR があればその中身が置き換わる。
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/templates"
branch=templates/apply
self=github-templates

files_of() {
  case "$1" in
    secret-scan) echo ".github/workflows/secret-scan.yml" ;;
    claude) echo ".github/workflows/claude.yml" ;;
    session-start) echo ".claude/settings.json .claude/hooks/session-start.sh" ;;
    *) return 1 ;;
  esac
}

# 組ごとに、取り込んだあと人がやること (PR の本文に載せる)
todo_of() {
  case "$1" in
    secret-scan)
      echo "- Secret scan: 必須チェックにするなら、ルールセットの必須チェックに \`scan / Scan\` を足す (github-templates の「ルールセットを適用」で \`required_check\` に指定する)。一度 CI が走ってから足すこと" ;;
    claude)
      echo "- Claude: Settings → Secrets and variables → Actions に \`CLAUDE_CODE_OAUTH_TOKEN\` を登録する (\`claude setup-token\` で得る)。Claude GitHub App がこのリポジトリに入っているかも確かめる。issue_comment で起動するので、既定ブランチに入ってから効く" ;;
    session-start)
      echo "- session-start: Claude Code on the web のセッションでだけ動く (手元では何もしない)。手元のフックは github-templates の README の手順で入れる" ;;
  esac
}

# ---- 1 リポジトリ分 (別プロセスで動かし、set -e を確実に効かせる) ----
if [ "${1:-}" = "--one" ]; then
  repo=$2
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT

  info=$(gh api "repos/$OWNER/$repo" --jq '[.default_branch, .private, .archived] | @tsv')
  IFS=$'\t' read -r default private archived <<<"$info"
  if [ "$archived" = "true" ]; then
    echo "⏭️  $repo: アーカイブ済み"
    exit 0
  fi
  if ! git clone -q --depth 1 --branch "$default" "https://github.com/$OWNER/$repo.git" "$work/repo" 2>"$work/clone.err"; then
    # 空のリポジトリは既定ブランチが無く clone できない
    echo "::warning::$repo: clone できない ($(tr '\n' ' ' <"$work/clone.err"))"
    exit 1
  fi
  dir="$work/repo"

  added=() updated=() skipped=() sets_done=()
  IFS=',' read -r -a sets <<<"$SETS"
  for set in "${sets[@]}"; do
    set=$(echo "$set" | tr -d '[:space:]')
    [ -n "$set" ] || continue
    files=$(files_of "$set") || { echo "::error::知らない組: $set"; exit 1; }
    touched=false
    for f in $files; do
      dst="$dir/$f"
      # .gitignore で外しているパス (.claude/ を丸ごと外しているリポジトリなど) は、意図して外しているとみなす
      if git -C "$dir" check-ignore -q --no-index -- "$f"; then
        skipped+=("\`$f\`: .gitignore で外している。入れるなら .gitignore を直してから流し直す")
        continue
      fi
      if [ -e "$dst" ]; then
        # 改行コードの違いだけなら同じとみなす
        if cmp -s <(tr -d '\r' <"$dst") <(tr -d '\r' <"$src/$f"); then
          continue
        fi
        if [ "$f" = ".claude/settings.json" ]; then
          if grep -q 'session-start.sh' "$dst"; then
            continue
          fi
          skipped+=("\`$f\`: 既にほかの設定がある。雛形の SessionStart フックを手で足す")
          continue
        fi
        if [ "${OVERWRITE:-false}" != "true" ]; then
          skipped+=("\`$f\`: 雛形と中身が違う (リポジトリ固有の変更かもしれないので上書きしない)")
          continue
        fi
        updated+=("$f")
      else
        added+=("$f")
      fi
      mkdir -p "$(dirname "$dst")"
      cp "$src/$f" "$dst"
      touched=true
    done
    if [ "$touched" = true ]; then sets_done+=("$set"); fi
  done

  for s in "${skipped[@]+"${skipped[@]}"}"; do echo "::warning::$repo: $s"; done
  if [ ${#added[@]} -eq 0 ] && [ ${#updated[@]} -eq 0 ]; then
    echo "✅ $repo: 変更なし"
    exit 0
  fi

  cd "$dir"
  git add -- "${added[@]+"${added[@]}"}" "${updated[@]+"${updated[@]}"}"
  for f in "${added[@]+"${added[@]}"}" "${updated[@]+"${updated[@]}"}"; do
    case "$f" in *.sh) git update-index --chmod=+x "$f" ;; esac
  done

  list=$(printf '%s\n' "${added[@]+"${added[@]}"}" "${updated[@]+"${updated[@]}"}" | sed '/^$/d' | sed 's/^/`/; s/$/`/' | paste -sd ' ' -)
  body="$work/body.md"
  {
    echo "[github-templates](https://github.com/$OWNER/$self) の雛形 (\`templates/\`) を入れる。"
    echo
    for f in "${added[@]+"${added[@]}"}"; do echo "- 追加: \`$f\`"; done
    for f in "${updated[@]+"${updated[@]}"}"; do echo "- 雛形の版に置き換え: \`$f\`"; done
    if [ ${#skipped[@]} -gt 0 ]; then
      echo
      echo "### 入れなかったもの"
      echo
      for s in "${skipped[@]}"; do echo "- $s"; done
    fi
    echo
    echo "### マージしたあとにやること"
    echo
    for s in "${sets_done[@]}"; do todo_of "$s"; done
    if [ "$private" = "true" ]; then
      echo "- 非公開リポジトリなので、追加したワークフローの実行時間は Actions の無料枠から引かれる"
    fi
    echo
    echo "この PR は github-templates の「雛形を配布」(apply-templates.yml) が作った。"
    echo "流し直すとブランチ \`$branch\` が既定ブランチから作り直され、この PR の中身が置き換わる。"
  } >"$body"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "🔍 $repo: (DRY_RUN) PR を作る予定: $list"
    sed 's/^/    /' "$body"
    exit 0
  fi

  git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" commit -q -m "github-templates の雛形を入れる" -m "$list"
  git push -q -f origin "HEAD:refs/heads/$branch"

  pr=$(gh pr list -R "$OWNER/$repo" --head "$branch" --state open --json url --jq '.[0].url // ""')
  if [ -n "$pr" ]; then
    gh pr edit "$pr" --body-file "$body" >/dev/null
    echo "🔁 $repo: PR を更新 $pr"
  else
    pr=$(gh pr create -R "$OWNER/$repo" --base "$default" --head "$branch" \
      --title "github-templates の雛形を入れる" --body-file "$body")
    echo "🆕 $repo: PR を作成 $pr"
  fi
  exit 0
fi

# ---- 全体 ----
: "${OWNER:?OWNER が未設定}" "${REPOS:?REPOS が未設定}" "${SETS:?SETS が未設定}"

if [ "${DRY_RUN:-0}" != "1" ]; then
  # コミットの名義はトークンの持ち主にする (noreply のアドレス)
  if [ -z "${GIT_NAME:-}" ] || [ -z "${GIT_EMAIL:-}" ]; then
    IFS=$'\t' read -r login uid <<<"$(gh api user --jq '[.login, .id] | @tsv')"
    export GIT_NAME="$login" GIT_EMAIL="$uid+$login@users.noreply.github.com"
  fi
fi

if [ "$REPOS" = "all" ]; then
  targets=$(gh repo list "$OWNER" --source --no-archived --limit 1000 --json name --jq '.[].name' | grep -vx "$self" || true)
else
  targets=$(echo "$REPOS" | tr ',' ' ')
fi

failed=()
for repo in $targets; do
  if [ "$repo" = "$self" ]; then
    echo "⏭️  $repo: このリポジトリ自身には入れない (自前の Self check で検査している)"
    continue
  fi
  if ! OWNER="$OWNER" SETS="$SETS" bash "$0" --one "$repo"; then
    failed+=("$repo")
  fi
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "::error::失敗したリポジトリ: ${failed[*]}"
  exit 1
fi
