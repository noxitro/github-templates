#!/bin/sh
# フックの入口 (pre-commit / commit-msg / pre-push) から . で読み込み、
# リポジトリ固有のフック (.git/hooks/<名前>) を続けて呼ぶ。
#
# global の core.hooksPath を設定すると、git は .git/hooks を見なくなる。
# git lfs install などが入れたリポジトリ固有のフックが黙って止まらないよう、
# 共通の検査が通ったあと (対象外のリポジトリでは検査なしで) ここから呼ぶ。
#
# 使い方: nox_run_local_hook <名前> [引数...]   (標準入力はそのまま渡る)
#         終了コードはリポジトリ固有のフックのもの。無ければ 0。

nox_run_local_hook() {
  name=$1
  shift
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
  hook="$common/hooks/$name"
  [ -f "$hook" ] && [ -x "$hook" ] || return 0
  "$hook" "$@"
}
