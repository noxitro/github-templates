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

# 組織の文脈を書いてよい非公開リポジトリか (org-context-allowed.txt に載っているか)。
# 載っていれば、所属組織の文脈を示す語の検査だけを外す (NOX_ALLOW_ORG_CONTEXT=1)。
# 秘密情報・個人情報などほかの検査はそのまま効く。
# 判定は push 先 / origin の URL で行うので、リポジトリの中身を書き換えても外せない。
nox_org_context_allowed() {
  slug=$(nox_repo_slug "${1:-}")
  [ -n "$slug" ] || return 1
  grep -v '^#' "$(dirname "$0")/org-context-allowed.txt" 2>/dev/null | tr 'A-Z' 'a-z' | grep -qxF "$slug"
}
