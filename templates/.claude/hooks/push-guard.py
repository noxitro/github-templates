# push-guard.sh から呼ぶ判定の本体。入力 (フックの JSON) は環境変数 PUSH_GUARD_INPUT で受け取る。
# 結果は標準出力に、1 行目が allow / deny / check、2 行目以降が理由 (deny) か作業ディレクトリ (check)。
import json
import os
import re
import sys

d = json.loads(os.environ["PUSH_GUARD_INPUT"])
tool = d.get("tool_name") or ""
cmd = (d.get("tool_input") or {}).get("command") or ""
cwd = d.get("cwd") or ""

def out(*lines):
    sys.stdout.write("\n".join(lines))
    sys.exit(0)

if tool.startswith("mcp__"):
    if re.search(r"push_files|create_or_update_file|delete_file|create_commit|update_file|commit_files", tool, re.I):
        out("deny", f"{tool} は GitHub の API で直接コミットするので、pre-push の検査を通らない。")
    out("allow")
if tool not in ("Bash", "PowerShell"):
    out("allow")

# gh api でのファイル・コミットの書き込み (git のフックを通らない)。
if (re.search(r"(^|[^\w-])gh\s+api(\s|$)", cmd) and re.search(r"/(contents|git)/", cmd)
        and re.search(r"(-X|--method)[\s=]*(PUT|POST|PATCH|DELETE)|(^|\s)(-f|-F|--field|--raw-field|--input)([\s=]|$)", cmd)):
    out("deny", "gh api でのファイル・コミットの書き込みは pre-push を通らない。")

# 引用符の中を落とす。空白を含むもの (メッセージや本文) は 1 語の印に置き換え、含まないものは外す ("git" -> git)。
def unquote(m):
    body = m.group(0)[1:-1]
    return "Q" if re.search(r"\s", body) or body == "" else body
plain = re.sub(r'"(?:\\.|[^"\\])*"|\'[^\']*\'', unquote, cmd)

# コマンドの区切りで分け、各部分の git のサブコマンドを見る。
GLOBAL_WITH_ARG = {"-c", "-C", "--git-dir", "--work-tree", "--namespace", "--config-env", "--exec-path"}
pushing = False
for seg in re.split(r"[;&|()\n`]|\$\(", plain):
    words = seg.split()
    while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
        words.pop(0)
    if not words or os.path.basename(words[0]).lower() not in ("git", "git.exe"):
        continue
    i = 1
    while i < len(words) and words[i].startswith("-"):
        i += 2 if words[i] in GLOBAL_WITH_ARG else 1
    sub = words[i] if i < len(words) else ""
    if sub == "send-pack":
        out("deny", "git send-pack は pre-push を通らない。")
    if sub == "push":
        pushing = True
if not pushing:
    out("allow")

one = cmd.strip()
ref = r"[A-Za-z0-9._/:+@^~{}][A-Za-z0-9._/:+@^~{}-]*"
form = rf"git push(?: (?:-u|--set-upstream|--force-with-lease(?:={ref})?|--delete|-d|--tags))*(?: origin)?(?: {ref})*"
if "\n" in one or not re.fullmatch(form, one):
    out("deny", f"決まった形でない git push は通さない (単独の 1 行で、git と push の間に何も挟まない): {one}")
out("check", cwd)
