#!/bin/sh
# gitleaks を見つけて実行する薄いラッパー。引数はそのまま gitleaks git に渡す。
#
# scan.sh の手書きパターンは 9 種類しかない。gitleaks は 150 以上の
# ルールを持つので、入っているなら併用する。ただし全員の環境に
# 入っているとは限らないので、無ければ警告だけ出して先へ進む
# (フックが壊れて誰も使わなくなるのが一番まずい)。
#
# 本当に迂回不可能な関門は GitHub の push protection であって、
# ここではない。これはその手前で気付くための層。
set -u

find_gitleaks() {
  p=$(command -v gitleaks 2>/dev/null) && { printf '%s\n' "$p"; return 0; }
  # winget で入れると PATH に載らないことがあるので直接見る。
  # ~/.local/bin は install-gitleaks.sh が /usr/local/bin に書けないときの置き場。
  for p in \
    "${LOCALAPPDATA:-}/Microsoft/WinGet/Links/gitleaks.exe" \
    "${HOME:-}/AppData/Local/Microsoft/WinGet/Links/gitleaks.exe" \
    /usr/local/bin/gitleaks /opt/homebrew/bin/gitleaks "${HOME:-}/.local/bin/gitleaks"
  do
    [ -n "$p" ] && [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

if ! GL=$(find_gitleaks); then
  echo "  note: gitleaks が無いので組み込みパターンのみで検査した。" >&2
  echo "        導入すると検出範囲が広がる: winget install Gitleaks.Gitleaks" >&2
  exit 0
fi

# 設定はリポジトリの .gitleaks.toml を優先し、無ければ共通の gitleaks.toml を使う。
# リポジトリ側で書くときは、共通側のルール (Discord の Webhook URL など) も写しておくこと。
ROOT=$(git rev-parse --show-toplevel) || exit 1
CONFIG="$ROOT/.gitleaks.toml"
[ -f "$CONFIG" ] || CONFIG="$(dirname "$0")/gitleaks.toml"

out=$(mktemp) || exit 0
trap 'rm -f "$out"' EXIT INT TERM

if "$GL" git "$ROOT" --config "$CONFIG" --no-banner --redact --exit-code 1 "$@" >"$out" 2>&1; then
  exit 0
fi

cat "$out" >&2
cat >&2 <<'MSG'

  --------------------------------------------------------------------
  gitleaks が秘密情報を検出した。上の出力を確認すること。
  誤検知ならリポジトリの .gitleaks.toml の allowlist に足す。
  --------------------------------------------------------------------
MSG
exit 1
