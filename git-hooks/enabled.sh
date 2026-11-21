#!/bin/sh
# フックの入口 (pre-commit / commit-msg / pre-push) から . で読み込み、
# このリポジトリで検査するかを決める。
#
# global の core.hooksPath で全リポジトリに当てているので、他者のリポジトリ
# (GPL のプロジェクトや他者の著作権表示を含むもの) を clone してコミットしたときまで
# 止めてしまわないよう、既定では自分のリポジトリだけを対象にする。
#
#   git config nox.hooks true   … 対象外のリポジトリでも検査する (remote が無いものなど)
#   git config nox.hooks false  … このリポジトリでは検査しない
#
# 使い方: . "$DIR/enabled.sh"; nox_hooks_enabled [<remote の URL>] || exit 0

NOX_HOOKS_OWNER=noxitro

nox_hooks_enabled() {
  case "$(git config --bool nox.hooks 2>/dev/null)" in
    true) return 0 ;;
    false) return 1 ;;
  esac
  # pre-push は push 先の URL を受け取るのでそれで見る。ほかは origin で判定する。
  # クラウドのセッションでは origin がプロキシ経由 (http://.../git/<owner>/<repo>) になるが、
  # 末尾の <owner>/<repo> は同じ形なので同じ判定で拾える。
  url=${1:-$(git remote get-url origin 2>/dev/null || true)}
  printf '%s\n' "$url" | grep -qiE "[:/]${NOX_HOOKS_OWNER}/[^/]+/?$"
}

# remote の URL (省略時は origin) から <owner>/<repo> を取り出す。末尾の .git と / は落とす。
nox_repo_slug() {
  url=${1:-$(git remote get-url origin 2>/dev/null || true)}
  printf '%s\n' "$url" | sed -E 's#/+$##; s#\.git$##' | grep -oE '[^/:]+/[^/:]+$' | tr 'A-Z' 'a-z'
}

# 手元にだけ置く一覧 (既定 ~/.config/nox/<名前>) を、コメントと空行を除いて 1 行ずつ出す。
# 非公開リポジトリの名前を含む一覧は、公開しているこのリポジトリには置かない。
# CR・前後の空白は落とす (Windows で書いた CRLF のファイルが黙って一致しなくなるのを防ぐ)。
# 環境変数で場所を指したのにファイルが無いときは、検査が黙って変わらないよう警告する。
#   nox_local_list <環境変数の値 (空なら既定の場所)> <ファイル名>
nox_local_list() {
  nox_list_file=${1:-${HOME:-}/.config/nox/$2}
  if [ ! -f "$nox_list_file" ]; then
    [ -z "$1" ] || echo "hooks: 指定された $nox_list_file が無い ($2 として読む一覧)" >&2
    return 0
  fi
  tr -d '\r' < "$nox_list_file" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v -e '^#' -e '^$'
}

# 組織の文脈を書いてよい非公開リポジトリか (手元の org-context-allowed.txt に載っているか)。
# 載っていれば、所属組織の文脈を示す語の検査だけを外す (NOX_ALLOW_ORG_CONTEXT=1)。
# 秘密情報・個人情報などほかの検査はそのまま効く。
# 判定は push 先 / origin の URL で行うので、リポジトリの中身を書き換えても外せない。
# 一覧は手元にしか無いので、クラウドのセッションではこの語の検査が外れない (安全側)。
#   場所: ~/.config/nox/org-context-allowed.txt (NOX_ORG_CONTEXT_ALLOWED で変えられる)。1 行 1 つ <owner>/<repo>
nox_org_context_allowed() {
  slug=$(nox_repo_slug "${1:-}")
  [ -n "$slug" ] || return 1
  nox_local_list "${NOX_ORG_CONTEXT_ALLOWED:-}" org-context-allowed.txt | tr 'A-Z' 'a-z' | grep -qxF "$slug"
}
