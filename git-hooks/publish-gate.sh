#!/bin/sh
# 公開リポジトリへの push を、非公開リポジトリを経由し、公開前レビューを通ったものだけに絞る (pre-push から呼ぶ)。
#
#   publish-gate.sh <push 先の URL> <local_sha> <remote_sha>
#
# push 先が publish-gated.txt に載っていなければ何もしない。載っていれば、push する範囲の
# コミットそれぞれのツリーが、非公開リポジトリの main の履歴に現れた <置き場> のツリーの
# どれかと一致するかを見る。一致しないコミットが 1 つでもあれば終了コード 1。
#
# 非公開リポジトリは ~/.cache/nox/publish-gate/ に blob 無しの bare clone で持ち、毎回 fetch する
# (比べるのはツリーのハッシュだけなので blob は要らない)。取得できなければ止める (検査できないのに通さない)。
set -u
DIR=$(dirname "$0")
. "$DIR/enabled.sh"
ZERO=0000000000000000000000000000000000000000
url=$1 local_sha=$2 remote_sha=$3

slug=$(nox_repo_slug "$url")
[ -n "$slug" ] || exit 0
line=$(grep -v '^#' "$DIR/publish-gated.txt" 2>/dev/null | awk -v s="$slug" 'tolower($1) == s { print; exit }')
[ -n "$line" ] || exit 0
# shellcheck disable=SC2086
set -- $line
staging=$2 prefix=$3 reviews=${4:-}

fail() {
  echo "publish-gate: $slug への push を止めた。$1" >&2
  echo "  公開する内容は、先に $staging の $prefix/ に入れて main に push し、そのツリーを公開側へ写す" >&2
  echo "  (agent-toolkit-private の scripts/publish-public.mjs)。" >&2
  exit 1
}

cache="${XDG_CACHE_HOME:-$HOME/.cache}/nox/publish-gate/$(printf '%s' "$staging" | tr '/' '_').git"
if [ ! -d "$cache" ]; then
  mkdir -p "$(dirname "$cache")"
  git clone -q --bare --filter=blob:none "https://github.com/$staging.git" "$cache" 2>/dev/null ||
    { rm -rf "$cache"; fail "$staging を取得できない (認証かネットワーク)。"; }
fi
git -C "$cache" fetch -q --filter=blob:none origin '+refs/heads/main:refs/heads/main' 2>/dev/null ||
  fail "$staging の main を取得できない (認証かネットワーク)。"

allowed=$(mktemp) || exit 1
trap 'rm -f "$allowed"' EXIT INT TERM
git -C "$cache" log --format=%H main -- "$prefix" |
  while read -r c; do git -C "$cache" rev-parse -q --verify "$c:$prefix" 2>/dev/null; done | sort -u > "$allowed"
[ -s "$allowed" ] || fail "$staging の main に $prefix/ が無い。"

if [ "$remote_sha" = "$ZERO" ]; then
  commits=$(git rev-list "$local_sha" --not --remotes)
else
  commits=$(git rev-list "$remote_sha..$local_sha")
fi
bad=0
for c in $commits; do
  tree=$(git rev-parse "$c^{tree}")
  if ! grep -qxF "$tree" "$allowed"; then
    echo "  [UNSTAGED] $(git log -1 --format='%h %s' "$c") — このツリーは $staging の $prefix/ に無い" >&2
    bad=1
  elif [ -n "$reviews" ] && [ -z "$(git -C "$cache" ls-tree --name-only main -- "$reviews/$tree.pass")" ]; then
    echo "  [UNREVIEWED] $(git log -1 --format='%h %s' "$c") — このツリーの公開前レビューの PASS 記録が $staging の $reviews/ に無い" >&2
    bad=1
  fi
done
[ "$bad" -eq 0 ] || fail "非公開リポジトリを経由していないか、公開前レビューを通っていないコミットがある。"
exit 0
