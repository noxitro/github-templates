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
