#!/bin/sh
# 使える Python 3 の実行ファイル名を 1 行で出す。無ければ何も出さない。
# Windows の python3 は Microsoft Store への誘導スタブのことがあるので、実際に起動して確かめる。
for c in python3 python; do
  if "$c" -c 'import sys; sys.exit(sys.version_info[0] != 3)' >/dev/null 2>&1; then
    printf '%s\n' "$c"
    exit 0
  fi
done
exit 0
