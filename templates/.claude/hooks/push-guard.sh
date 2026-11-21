#!/bin/bash
# Claude Code の PreToolUse フック。エージェントの push が、共通の pre-push を通らずに外へ出るのを止める。
#
# 公開リポジトリでは push した時点で公開される。push の後の CI (Secret scan) では間に合わないので、
# pre-push が確実に走る形の push だけを通す。
#
#   Bash の git push   : 決まった形 (git push [-u] [--force-with-lease] [--delete] [--tags] [origin] [<ref>...])
#                        だけを通す。--no-verify (省略形を含む)、git と push の間のオプション (-c / -C など)、
#                        環境変数の代入、cd との組み合わせは止める。そのうえで、このリポジトリの実効の
#                        core.hooksPath が共通のフックを指していること、nox.hooks が false でないことを確かめる
#                        (フックを入れていない新しい端末や、SessionStart が失敗したクラウドのセッションで止まる)。
#   Bash の git send-pack / gh api による contents・git の書き込み : 常に止める (git のフックを通らない)。
#   MCP の GitHub ツールのうちファイルを書くもの (push_files / create_or_update_file など) : 常に止める。
#
# 事故を防ぐためのもので、わざと抜けようとするエージェントへの境界ではない
# (スクリプトに書いて実行する、などは見ていない)。
#
# 入力は標準入力の JSON (tool_name / tool_input / cwd)。止めるときは終了コード 2 と標準エラーの理由。
set -uo pipefail

deny() {
  echo "push-guard: $1" >&2
  echo "  push は共通の pre-push を通る形 (git push origin <ブランチ>) で行う。フックの導入は github-templates の README。" >&2
  exit 2
}

input=$(cat)

py=''
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import json' >/dev/null 2>&1; then py=$c; break; fi
done

field() {
  # $1: tool_name / command / cwd
  printf '%s' "$input" | "$py" -c '
import json, sys
d = json.load(sys.stdin)
k = sys.argv[1]
v = d.get("tool_name") if k == "tool_name" else d.get("cwd") if k == "cwd" else (d.get("tool_input") or {}).get("command")
sys.stdout.write(v or "")
' "$1" 2>/dev/null
}

if [ -n "$py" ]; then
  tool=$(field tool_name)
  cmd=$(field command)
  cwd=$(field cwd)
else
  # JSON を読めないときは、push に関係しそうなら止める (判定できないのに通さない)。
  tool='' cmd=$input cwd=''
fi

# MCP の GitHub ツールでファイルやコミットを作るもの。
case "$tool" in
  mcp__*)
    if printf '%s' "$tool" | grep -qiE 'push_files|create_or_update_file|delete_file|create_commit|update_file|commit_files'; then
      deny "$tool は GitHub の API で直接コミットするので、pre-push の検査を通らない。"
    fi
    exit 0 ;;
esac

# git のフックを通らない書き込み。
if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_-])send-pack([^[:alnum:]_-]|$)'; then
  deny "git send-pack は pre-push を通らない。"
fi
if printf '%s' "$cmd" | grep -qE '(^|[^[:alnum:]_-])gh[[:space:]]+api([[:space:]]|$)' &&
   printf '%s' "$cmd" | grep -qE '/(contents|git)/' &&
   printf '%s' "$cmd" | grep -qE '(-X|--method)[[:space:]=]*(PUT|POST|PATCH|DELETE)|(^|[[:space:]])(-f|-F|--field|--raw-field|--input)([[:space:]=]|$)'; then
  deny "gh api でのファイル・コミットの書き込みは pre-push を通らない。"
fi

# git ... push の形が含まれるか (git と push の間にオプションがあっても拾う)。
# 'push' のように引用符で囲んだものや pre-push のようなパスの一部は拾わない。
if ! printf '%s' "$cmd" | grep -qE '(^|[;&|(`[:space:]])git([[:space:]]+[^;&|[:space:]]+)*[[:space:]]+push([[:space:];&|)]|$)'; then
  exit 0
fi

[ -n "$py" ] || deny "Python が無く、コマンドを読めないので push を判定できない。"

# 前後の空白を落として、決まった形かを見る。
one=$(printf '%s' "$cmd" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
[ "$(printf '%s\n' "$one" | wc -l)" -eq 1 ] || deny "push は 1 行の git push だけで実行する (複数行のコマンドに混ぜない)。"
# 先頭が - のものはオプションなので、<ref> としては受けない。
ref='[A-Za-z0-9._/:+@^~{}][A-Za-z0-9._/:+@^~{}-]*'
if ! printf '%s' "$one" | grep -qE "^git push(( -u| --set-upstream| --force-with-lease(=$ref)?| --delete| -d| --tags))*( origin)?( $ref)*$"; then
  deny "決まった形でない git push は通さない: $one"
fi

# 以下の判定は git 自身に読ませる。このフックはエージェントのコマンドと同じ環境変数で動くので、
# GIT_CONFIG_COUNT / GIT_CONFIG_GLOBAL などで設定を変えていても、push のときと同じ実効値が見える
# (認証や名義を GIT_CONFIG_* で与える環境もあるので、変数があること自体では止めない)。
cd "${cwd:-.}" 2>/dev/null || deny "作業ディレクトリ ${cwd:-} に入れない。"
hp=$(git config core.hooksPath 2>/dev/null || true)
[ -n "$hp" ] || deny "core.hooksPath が設定されていない (共通のフックが入っていない)。"
case "$hp" in
  /* | [A-Za-z]:[\/]* | '~'*) ;;
  *) hp="$(git rev-parse --show-toplevel 2>/dev/null)/$hp" ;;
esac
case "$hp" in '~'*) hp="${HOME:-}${hp#\~}" ;; esac
for f in pre-push enabled.sh scan.sh; do
  [ -f "$hp/$f" ] || deny "core.hooksPath ($hp) が共通のフックを指していない ($f が無い)。"
done
[ "$(git config --bool nox.hooks 2>/dev/null)" != false ] || deny "このリポジトリは nox.hooks = false で、pre-push の検査が外れている。"
exit 0
