#!/bin/sh
# 公開リポジトリに出してはいけないものを検出する共通スキャナ。
# pre-commit と pre-push の両方から呼ばれる。
#
# 標準入力から "<path>\t<blob-ish>" を 1 行ずつ受け取る。blob-ish は
# git cat-file にそのまま渡せる形 (pre-commit なら ":path"、pre-push なら
# "<sha>:path")。検出したら理由を表示して終了コード 1 を返す。
#
# 初回 push では数千ファイルが流れてくるので、中身の検査は
# git cat-file --batch 一発にまとめてある。何か見つかったときだけ、
# 場所を特定するために個別に読み直す (遅い経路は異常時しか通らない)。
#
# 誤検出を握り潰したいときは .githooks-allow に 1 行 1 パスで書く。
set -u

ROOT=$(git rev-parse --show-toplevel)
ALLOW="$ROOT/.githooks-allow"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
FOUND=0
MAX_BYTES=$((5 * 1024 * 1024))

note() { FOUND=1; printf '  [%s] %s\n    %s\n' "$1" "$2" "$3" >&2; }

# 秘密情報。誤検出の少ない、発行元が特定できる形式だけを並べている。
SECRET_RE='BEGIN (RSA|OPENSSH|DSA|EC|PGP) PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{30}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|xox[abprs]-[0-9A-Za-z-]{10}|sk-ant-[A-Za-z0-9_-]{20}|discord(app)?\.com/api/(v[0-9]+/)?webhooks/[0-9]{17,20}/[A-Za-z0-9_-]{60}|(mongodb\+srv|mongodb|postgresql|postgres|mysql|redis|amqp)://[^:/[:space:]]+:[^@[:space:]]+@'
# 個人情報。履歴から除去済みなので、再流入をここで止める。
PERSONAL_RE='[A-Za-z]:[\/]{1,2}Users[\/]{1,2}[A-Za-z0-9._-]+|[A-Za-z0-9._%+-]+@(gmail|outlook|yahoo|icloud|hotmail)\.[A-Za-z.]{2,}'
# ライセンス。自分のリポジトリは MIT なので、コピーレフトや再配布を禁じる文言が入ったら止める。
# 大文字小文字は揃わないので -i で見る。reserve[d] と書いているのは、このファイル自身に当たらないため。
LICENSE_RE='GNU (Lesser |Library |Affero )?General Public License|SPDX-License-Identifier:[[:space:]]*(A|L)?GPL|All rights reserve[d]'
# 他者の著作権表示。自分の表示 (Copyright (c) 2023-XXXX noxitro など) 以外は、コードの引き写しを疑う。
# (c) の無い、年が直後に続く形 (Copyright <年> <名前>) も拾う。
COPYRIGHT_RE='copyright[[:space:]]*(\(c\)|©|[0-9]{4})'
# nitro は github-templates の LICENSE の表記。他者の "2019 Nitro Software" などを通さないよう、行末まで一致させる。
OWN_COPYRIGHT_RE='noxitro|\(c\)[[:space:]]+[0-9]{4}(-[0-9]{4})?[[:space:]]+nitro[[:space:]]*$'
# 家庭用ゲーム機の非公開 SDK (NDA 下で配布されるもの) の識別子。ヘッダ・名前空間・関数と
# マクロの命名規則で見る。製品名ではなく、コードに現れる形だけを並べている。
# nn:: は直前が :: のもの (torch::nn::functional:: などのニューラルネット系) を外す。
NDA_RE='#include[[:space:]]*[<"](nn|sce)[/_]|(^|[^A-Za-z0-9_:])nn::[a-z]+::|(^|[^A-Za-z0-9_])SCE_[A-Z][A-Z_]+|(^|[^A-Za-z0-9_])sce[A-Z][a-z]+[A-Z][A-Za-z0-9]*[[:space:]]*\('

# このマシンのユーザー名・ホスト名。テスト結果 (.trx の runUser="HOST\user") や
# ログに紛れ込む形で実際に混入したので、値を固定せず実行環境から取る。
# 大文字小文字は揃わない (hostname は小文字、Windows の表示は大文字) ので -i で見る。
re_escape() { printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g'; }
ME=$(id -un 2>/dev/null || printf '%s' "${USERNAME:-}")
HOST=$(hostname 2>/dev/null || printf '%s' "${COMPUTERNAME:-}")
LOCAL_RE=''
if [ -n "$ME" ]; then
  ME_RE=$(re_escape "$ME")
  LOCAL_RE="[\/]Users[\/]${ME_RE}([^A-Za-z0-9_]|\$)|[\/]${ME_RE}[\/]"
  [ -n "$HOST" ] && LOCAL_RE="${LOCAL_RE}|$(re_escape "$HOST")[\/]{1,2}${ME_RE}([^A-Za-z0-9_]|\$)"
fi

cat > "$TMP/in.txt"
[ -s "$TMP/in.txt" ] || exit 0

# --- 1. パスによる判定 (サブプロセスを起こさないので速い) -------------------
: > "$TMP/objs.txt"
while IFS="$(printf '\t')" read -r path obj; do
  [ -n "$path" ] || continue
  if [ -f "$ALLOW" ] && grep -Fxq "$path" "$ALLOW" 2>/dev/null; then continue; fi

  case "$path" in
    # Nox で実際に何度も混入してきたもの。.gitignore をすり抜けて
    # git add -f された場合にここで止める。
    */obj/*|obj/*|*/.vs/*|.vs/*|*/x64/Debug/*|*/x64/Release/*|*.tlog/*)
      note ARTIFACT "$path" "ビルド/IDE 生成物。ローカル絶対パスを埋め込むため公開不可" ;;
    *.pdb|*.idb|*.ilk|*.iobj|*.ipdb|*.exp|*.suo|*.user|*.cache|*.ifc|*.i)
      note ARTIFACT "$path" "ビルド副産物。.gitignore を確認すること" ;;
    *.VC.db|*.db-wal|*.db-shm)
      note ARTIFACT "$path" "Visual Studio のローカル DB。ソース断片とパスを含む" ;;
    *.trx|TestResults/*|*/TestResults/*)
      note ARTIFACT "$path" "テスト実行の出力。実行ユーザー名 (runUser) と絶対パスを含む" ;;
    *.pem|*.key|*.pfx|*.p12|*.jks|*.keystore|*.snk|*.ppk|*.ovpn|.netrc|*.npmrc)
      note CREDENTIAL-FILE "$path" "鍵・証明書の拡張子" ;;
    .env|.env.*|*/.env|*/.env.*|id_rsa|id_dsa|id_ecdsa|id_ed25519|*/id_rsa|*/id_ed25519)
      note CREDENTIAL-FILE "$path" "秘密情報を置く定番のファイル名" ;;
  esac
  printf '%s\t%s\n' "$path" "$obj" >> "$TMP/objs.txt"
done < "$TMP/in.txt"
[ -s "$TMP/objs.txt" ] || { [ "$FOUND" -eq 0 ] && exit 0; }

# --- 2. サイズ (batch-check 一発) -------------------------------------------
cut -f2 "$TMP/objs.txt" | git cat-file --batch-check='%(objectname) %(objecttype) %(objectsize)' 2>/dev/null \
  | paste -d'\t' - "$TMP/objs.txt" 2>/dev/null \
  | while IFS="$(printf '\t')" read -r info path _obj; do
      set -- $info
      [ "${2:-}" = "blob" ] || continue
      [ "${3:-0}" -gt "$MAX_BYTES" ] || continue
      printf '%s\t%s\n' "$path" "$3"
    done > "$TMP/big.txt"
while IFS="$(printf '\t')" read -r path size; do
  [ -n "$path" ] || continue
  note SIZE "$path" "$((size / 1024)) KB — 上限 $((MAX_BYTES / 1024)) KB を超過。成果物の混入を疑うこと"
done < "$TMP/big.txt"

# --- 3. 中身 (まず全体を一度だけ走査する) -----------------------------------
cut -f2 "$TMP/objs.txt" | git cat-file --batch 2>/dev/null > "$TMP/blobs.bin"
if grep -a -q -E "$SECRET_RE|$PERSONAL_RE|$NDA_RE" "$TMP/blobs.bin" \
   || grep -a -q -i -E "$LICENSE_RE" "$TMP/blobs.bin" \
   || grep -a -i -E "$COPYRIGHT_RE" "$TMP/blobs.bin" | grep -a -q -v -i -E "$OWN_COPYRIGHT_RE" \
   || { [ -n "$LOCAL_RE" ] && grep -a -q -i -E "$LOCAL_RE" "$TMP/blobs.bin"; }; then
  # ここに来るのは異常時だけなので、個別に読み直して場所を特定する。
  while IFS="$(printf '\t')" read -r path obj; do
    body=$(git cat-file blob "$obj" 2>/dev/null) || continue
    hit=$(printf '%s' "$body" | grep -a -o -E "$SECRET_RE" 2>/dev/null | head -1)
    [ -n "$hit" ] && note SECRET "$path" "$(printf '%s' "$hit" | cut -c1-40)…"
    hit=$(printf '%s' "$body" | grep -a -o -E "$PERSONAL_RE" 2>/dev/null | head -1)
    [ -n "$hit" ] && note PERSONAL "$path" "$hit — ローカル絶対パス / 個人メールの露出"
    if [ -n "$LOCAL_RE" ]; then
      hit=$(printf '%s' "$body" | grep -a -o -i -E "$LOCAL_RE" 2>/dev/null | head -1)
      [ -n "$hit" ] && note PERSONAL "$path" "$hit — このマシンのユーザー名 / ホスト名の露出"
    fi
    hit=$(printf '%s' "$body" | grep -a -o -E "$NDA_RE" 2>/dev/null | head -1)
    [ -n "$hit" ] && note NDA "$path" "$hit — 非公開 SDK の識別子。NDA 下のコードやヘッダの混入を疑うこと"
    # Doxygen の生成物 (Nox の docs/doxygen) は同梱ライブラリの著作権表示を含むので、ライセンスの検査から外す。
    case "$path" in
      docs/doxygen/*) continue ;;
    esac
    hit=$(printf '%s' "$body" | grep -a -o -i -E "$LICENSE_RE" 2>/dev/null | head -1)
    [ -n "$hit" ] && note LICENSE "$path" "$hit — MIT と両立しないライセンス / 再配布を禁じる文言"
    hit=$(printf '%s' "$body" | grep -a -i -E "$COPYRIGHT_RE" 2>/dev/null | grep -a -v -i -E "$OWN_COPYRIGHT_RE" | head -1 | cut -c1-80)
    [ -n "$hit" ] && note LICENSE "$path" "$hit — 他者の著作権表示。引き写したコードならライセンスを確かめること"
  done < "$TMP/objs.txt"
fi

# --- 4. 外部資料の名前 -------------------------------------------------------
# 名前はハッシュで持っているので grep では見られない。Python に任せる。
# 手元に Python が無ければ飛ばす (CI の Secret scan が必ず見る)。
PY=$(sh "$(dirname "$0")/find-python.sh")
if [ -n "$PY" ]; then
  "$PY" "$(dirname "$0")/check-external-names.py" --blobs < "$TMP/objs.txt" || FOUND=1
else
  echo "scan.sh: Python が見つからないので外部資料名 (と手元の非公開リスト) の検査を飛ばした" >&2
fi

if [ "$FOUND" -ne 0 ]; then
  cat >&2 <<'MSG'

  --------------------------------------------------------------------
  公開リポジトリに出せないものが含まれている。
  修正するか、誤検出なら .githooks-allow にパスを 1 行で足すこと。
  どうしても通したいときだけ --no-verify を付ける。
  --------------------------------------------------------------------
MSG
  exit 1
fi
exit 0
