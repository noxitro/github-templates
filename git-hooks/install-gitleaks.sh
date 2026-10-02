#!/bin/sh
# gitleaks を固定バージョンで入れる (Linux 専用。クラウドのセッションと CI の Secret scan が使う)。
# 手元の Windows では winget install Gitleaks.Gitleaks で入れる。
#
# 使い方: install-gitleaks.sh [<置き場>]
#   置き場を省くと /usr/local/bin、書けなければ ~/.local/bin (gitleaks.sh の探索先) に入れる。
#   入れた (または既にあった) gitleaks のパスを標準出力に 1 行で出す。失敗したら終了コード 1。
#
# 版はここだけで管理する。SHA256 はリリースの checksums.txt から写したもので、
# リリース側の差し替えも検出できるよう、取得時に checksums.txt を読まずここに固定してある。
set -eu

GITLEAKS_VERSION=8.30.1
GITLEAKS_SHA256_LINUX_X64=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
GITLEAKS_SHA256_LINUX_ARM64=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080

if [ $# -ge 1 ]; then
  dest=$1
elif [ -w /usr/local/bin ]; then
  dest=/usr/local/bin
else
  dest="${HOME}/.local/bin"
fi

if [ -x "$dest/gitleaks" ]; then
  have=$("$dest/gitleaks" version 2>/dev/null || true)
  if [ "${have#v}" = "$GITLEAKS_VERSION" ]; then
    echo "install-gitleaks: gitleaks ${GITLEAKS_VERSION} は導入済み" >&2
    printf '%s\n' "$dest/gitleaks"
    exit 0
  fi
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    archive="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
    sha256=$GITLEAKS_SHA256_LINUX_X64 ;;
  Linux-aarch64)
    archive="gitleaks_${GITLEAKS_VERSION}_linux_arm64.tar.gz"
    sha256=$GITLEAKS_SHA256_LINUX_ARM64 ;;
  *)
    echo "install-gitleaks: この環境 ($(uname -s)-$(uname -m)) は未対応" >&2
    exit 1 ;;
esac

mkdir -p "$dest"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
cd "$tmp"
# クラウドのセッションでは SessionStart フックから同期で呼ばれるので、応答が止まったときに待たせ続けない。
curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 \
  "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${archive}" -o "$archive"
printf '%s  %s\n' "$sha256" "$archive" | sha256sum -c - >/dev/null
tar -xzf "$archive" gitleaks
install -m 0755 gitleaks "$dest/gitleaks"
echo "install-gitleaks: gitleaks $("$dest/gitleaks" version 2>/dev/null) を $dest に入れた" >&2
printf '%s\n' "$dest/gitleaks"
