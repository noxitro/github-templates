#!/bin/bash
# templates/.claude/hooks/push-guard.sh の回帰テスト。self-check から呼ぶ。手元でも bash tests/push-guard.sh で動く。
# 一時的なリポジトリを作り、core.hooksPath をこのリポジトリの git-hooks/ に向けて試す。
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
G="$ROOT/templates/.claude/hooks/push-guard.sh"
PY=$(command -v python3 >/dev/null 2>&1 && python3 -c 'import json' 2>/dev/null && echo python3 || echo python)
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
git -C "$T" init -q
git -C "$T" remote add origin https://github.com/noxitro/example
HOOKS=$(cd "$ROOT/git-hooks" && { pwd -W 2>/dev/null || pwd; })
git -C "$T" config core.hooksPath "$HOOKS"
CWD=$(cd "$T" && { pwd -W 2>/dev/null || pwd; })

fails=0
run() {
  exp=$1 tool=$2 cmd=$3
  json=$("$PY" -c 'import json,sys;print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"command":sys.argv[2]},"cwd":sys.argv[3]}))' "$tool" "$cmd" "$CWD")
  out=$(printf '%s' "$json" | bash "$G" 2>&1); rc=$?
  got=allow; [ "$rc" -eq 2 ] && got=deny; { [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; } && got="error($rc)"
  if [ "$got" = "$exp" ]; then
    printf 'ok   %-5s %s\n' "$got" "$(printf '%s' "$cmd" | head -1)"
  else
    printf 'FAIL %-5s (want %s) %s\n     %s\n' "$got" "$exp" "$(printf '%s' "$cmd" | head -1)" "$out"
    fails=$((fails + 1))
  fi
}

for c in "git push origin work/x" "git push -u origin HEAD" "git push" \
         "git push --force-with-lease origin work/x" "git push --delete origin work/old" "git push -u origin work/a work/b"; do
  run allow Bash "$c"
done
for c in "git push --no-verify origin x" "git push --no-verif origin x" "git push -n origin x" \
         "git -c core.hooksPath=/dev/null push origin x" "git -C other push" "cd sub && git push" \
         "GIT_CONFIG_COUNT=1 git push" "git push origin x; echo done" "git push origin x && echo y" \
         "$(printf 'git status\ngit push origin x')" "git push origin x | cat" "(git push origin x)" \
         "git --no-pager push origin x" "git push --repo=https://example.invalid origin" \
         "gh api -X PUT repos/o/r/contents/a.txt -f message=m" "gh api repos/o/r/git/refs -f ref=refs/heads/x" \
         "git send-pack origin x"; do
  run deny Bash "$c"
done
for c in "git log --grep 'push'" "cat git-hooks/pre-push" "git status" "echo push it" \
         "gh api repos/o/r/contents/a.txt" "grep -n push README.md" "git log --oneline origin/main..HEAD"; do
  run allow Bash "$c"
done
run deny mcp__github__push_files ""
run deny mcp__github__create_or_update_file ""
run allow mcp__github__get_file_contents ""

# 実効の設定で止まること
git -C "$T" config core.hooksPath "$T/nowhere"; run deny Bash "git push origin x"
git -C "$T" config --unset core.hooksPath; GIT_CONFIG_GLOBAL=/dev/null run deny Bash "git push origin x"
git -C "$T" config core.hooksPath "$HOOKS"
git -C "$T" config nox.hooks false; run deny Bash "git push origin x"; git -C "$T" config --unset nox.hooks
(
  n=${GIT_CONFIG_COUNT:-0}
  export "GIT_CONFIG_KEY_$n=core.hooksPath" "GIT_CONFIG_VALUE_$n=/dev/null" GIT_CONFIG_COUNT=$((n + 1))
  run deny Bash "git push origin x"
  exit "$fails"
) || fails=$((fails + 1))

echo "failures: $fails"
[ "$fails" -eq 0 ]
