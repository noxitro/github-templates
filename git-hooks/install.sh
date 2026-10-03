#!/bin/sh
# 全リポジトリでフックを有効にする (global の core.hooksPath をこのディレクトリへ向ける)。
# マシンごとに 1 回だけ実行すればよい。フックの更新はこのリポジトリを git pull するだけで効く。
#
# 対象は自分のリポジトリだけ (判定は enabled.sh)。無効化するには:
#   git config --global --unset core.hooksPath
set -eu
# Windows (Git for Windows の sh) では pwd が /c/... を返し、git 本体が読めないので C:/... の形にする。
DIR=$(cd "$(dirname "$0")" && { pwd -W 2>/dev/null || pwd; })
chmod +x "$DIR"/pre-commit "$DIR"/commit-msg "$DIR"/pre-push "$DIR"/post-* "$DIR"/*.sh "$DIR"/*.py 2>/dev/null || true
git config --global core.hooksPath "$DIR"
echo "core.hooksPath (global) = $DIR を設定した。"

# リポジトリごとの core.hooksPath は global より優先される。旧方式 (Nox の tools/git-hooks を
# 指していた) の設定が残っていると、ファイルを消したあとはフックが黙って走らなくなるので外す。
# ほかの値 (husky などのフック管理) は意図して置いたものなので触らず、知らせるだけにする。
if local_path=$(git config --local --get core.hooksPath 2>/dev/null); then
  case "$local_path" in
    tools/git-hooks)
      git config --local --unset core.hooksPath
      echo "このリポジトリの core.hooksPath (旧方式の $local_path) を外した。" ;;
    *)
      echo "note: このリポジトリは core.hooksPath = $local_path が優先され、共通のフックは走らない。" >&2 ;;
  esac
fi
