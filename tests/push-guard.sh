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
    printf 'ok   %-5s %-10s %s\n' "$got" "$tool" "$(printf '%s' "$cmd" | head -1)"
  else
    printf 'FAIL %-5s %-10s (want %s) %s\n     %s\n' "$got" "$tool" "$exp" "$(printf '%s' "$cmd" | head -1)" "$out"
    fails=$((fails + 1))
  fi
}

# 通す push (決まった形)
for c in "git push origin work/x" "git push -u origin HEAD" "git push" \
         "git push --force-with-lease origin work/x" "git push --delete origin work/old" \
         "git push -u origin work/a work/b"; do
  run allow Bash "$c"
done

# 止める push
for c in "git push --no-verify origin x" "git push --no-verif origin x" "git push -n origin x" \
         "git -c core.hooksPath=/dev/null push origin x" "git -C other push" "cd sub && git push" \
         "GIT_CONFIG_COUNT=1 git push" "git push origin x; echo done" "git push origin x && echo y" \
         "$(printf 'git status\ngit push origin x')" "git push origin x | cat" "(git push origin x)" \
         "git --no-pager push origin x" "git push --repo=https://example.invalid origin" \
         '"git" push --no-verify origin x' "git push '--no-verify' origin x" \
         "git add . && git commit -m wip && git push" "git push origin x 2>&1 | tail -5" \
         "gh api -X PUT repos/o/r/contents/a.txt -f message=m" "gh api repos/o/r/git/refs -f ref=refs/heads/x" \
         "git send-pack origin x" \
         "if git commit -m x; then git push --no-verify; fi" "for b in a b; do git push origin \$b; done" \
         "{ git push --no-verify; }" "! git push --no-verify" "time git push --no-verify" \
         "sudo git push --no-verify" "env X=1 git push --no-verify" "command git push --no-verify" \
         "echo x | xargs git push --no-verify" "/usr/bin/git push --no-verify origin x"; do
  run deny Bash "$c"
done
# 複数行・コメント・ヒアドキュメントの見かけで、後ろの push を見落とさない
for c in "$(printf 'git commit -F - <<< "wip"\ngit push --no-verify origin main')" \
         "$(printf 'echo $((1 << n))\ngit push --no-verify')" \
         "$(printf 'git commit -m "fix <<EOF handling"\ngit push --no-verify')" \
         "$(printf 'cat <<EOF-X\nbody\nEOF-X\ngit push --no-verify')" \
         "$(printf "cat <<'EOF'\nbody\nEOF\ngit push --no-verify")" \
         "$(printf "# Don't push tags\ngit push --no-verify origin main\n# that's it")" \
         "$(printf 'bash <<EOF\ngit push --no-verify\nEOF')" \
         'bash -c "git push --no-verify"' "sh -lc 'git push --no-verify origin x'" \
         'eval "git push --no-verify"' 'echo "$(git push --no-verify)"' \
         'git -c "user.name=A B" push origin x' \
         "git push origin x # done" \
         "git -c core.hooksPath=/dev/null subtree push --prefix=x origin main"; do
  run deny Bash "$c"
done
run deny PowerShell 'Set-Location "E:\repo\"; git push --no-verify origin main; Write-Host "done"'
run deny PowerShell "$(printf 'Write-Host "a"\n<# note #> git push --no-verify')"
run deny PowerShell 'pwsh -NoProfile -Command "git push --no-verify"'
run deny PowerShell 'git commit -m "say `"hi`""; git push --no-verify'
run allow PowerShell "$(printf "\$m = @'\nrun git push --no-verify later\n'@\ngit commit -m \$m")"
# 内部で git push するもの: フックが入っていれば通す (入っていないときは下の実効の設定の試験で止まる)
run allow Bash "gh repo create foo --public --source=. --push"
run allow Bash "git subtree push --prefix=x origin main"
run allow Bash "git subtree --prefix=x push origin main"
# 順番が違うだけの決まった形
run allow Bash "git push origin --delete work/old"
run allow Bash "git push origin work/x --force-with-lease"
run allow Bash "git push --follow-tags origin main"
run allow Bash 'git push origin "work/x"'
run allow Bash "git push 'origin' x"
run allow Bash "git push origin work/x 2>&1"
run allow Bash "git  push  origin work/x"
run allow Bash "$(printf 'git commit -F - <<EOF\nnote: git push origin main later\nEOF')"
run allow Bash "$(printf "cat > notes.md <<'EOF'\nrun git push --no-verify\nEOF")"

# PowerShell ツールも同じ判定
run allow PowerShell "git push origin work/x"
run deny PowerShell "git push --no-verify origin x"
run deny PowerShell "git push origin x; Write-Host done"
run allow PowerShell "git stash push -m wip"
run deny PowerShell 'git commit -m x; if ($?) { git push --no-verify }'
run deny PowerShell 'if ($LASTEXITCODE -eq 0) { git -c core.hooksPath=NUL push }'
run deny PowerShell '& git push --no-verify'
run deny PowerShell 'git.exe push --no-verify origin x'
run deny PowerShell '& "C:\Program Files\Git\cmd\git.exe" push --no-verify origin x'
run deny PowerShell '& "C:\Program Files\Git\cmd\git.exe" -c core.hooksPath=NUL push origin x'

# push ではないもの (誤検出しない)
for c in "git log --grep 'push'" "cat git-hooks/pre-push" "git status" "echo push it" \
         "gh api repos/o/r/contents/a.txt" "grep -n push README.md" "git log --oneline origin/main..HEAD" \
         'git commit -m "do not push directly to main"' "git stash push -m wip" \
         'gh pr create --body "after git push run ci"' 'gh issue comment 1 --body "please git push again"' \
         "grep -rn send-pack docs" "git log --grep=push" "git config --get core.hooksPath"; do
  run allow Bash "$c"
done
run allow Read ""
run deny mcp__github__push_files ""
run deny mcp__github__create_or_update_file ""
run allow mcp__github__get_file_contents ""
run deny mcp__github__delete_file ""
run allow mcp__filesystem__delete_file ""
run allow mcp__drive__update_file ""

# 実効の設定で止まること
git -C "$T" config core.hooksPath "$T/nowhere"; run deny Bash "git push origin x"
run deny Bash "gh repo create foo --public --source=. --push"; run deny Bash "git subtree push --prefix=x origin main"
git -C "$T" config --unset core.hooksPath; GIT_CONFIG_GLOBAL=/dev/null run deny Bash "git push origin x"
git -C "$T" config core.hooksPath "$HOOKS"
git -C "$T" config nox.hooks false; run deny Bash "git push origin x"; git -C "$T" config --unset nox.hooks
(
  n=${GIT_CONFIG_COUNT:-0}
  export "GIT_CONFIG_KEY_$n=core.hooksPath" "GIT_CONFIG_VALUE_$n=/dev/null" GIT_CONFIG_COUNT=$((n + 1))
  before=$fails
  run deny Bash "git push origin x"
  [ "$fails" -eq "$before" ]
) || fails=$((fails + 1))

# Python が使えない環境では、push に関係しうる入力を止める (読めないのに通さない)。
# 失敗するだけの python3 / python を PATH の先頭に置いて試す。
NOPY="$T/nopy"
mkdir -p "$NOPY"
for t in python3 python; do printf '#!/bin/sh\nexit 1\n' > "$NOPY/$t"; chmod +x "$NOPY/$t"; done
nopy() {
  exp=$1 json=$2
  printf '%s' "$json" | PATH="$NOPY:$PATH" bash "$G" >/dev/null 2>&1; rc=$?
  got=allow; [ "$rc" -eq 2 ] && got=deny
  if [ "$got" = "$exp" ]; then
    printf 'ok   %-5s (no python) %s\n' "$got" "$json"
  else
    printf 'FAIL %-5s (no python, want %s) %s\n' "$got" "$exp" "$json"
    fails=$((fails + 1))
  fi
}
nopy deny '{"tool_name":"Bash","tool_input":{"command":"git push --no-verify origin x"},"cwd":"."}'
nopy deny '{"tool_name":"mcp__github__push_files","tool_input":{},"cwd":"."}'
nopy allow '{"tool_name":"Bash","tool_input":{"command":"git status"},"cwd":"."}'

echo "failures: $fails"
[ "$fails" -eq 0 ]
