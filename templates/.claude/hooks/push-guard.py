# push-guard.sh から呼ぶ判定の本体。入力 (フックの JSON) は環境変数 PUSH_GUARD_INPUT で受け取る。
# 結果は標準出力に、1 行目が allow / deny / check、2 行目以降が理由 (deny) か作業ディレクトリ (check)。
import json
import os
import re
import sys

# 作業ディレクトリに日本語などが入っていても、呼び出し側 (bash) が読める形で返す。
sys.stdout.reconfigure(encoding="utf-8")

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


def is_git(word):
    # パスで書いた git (/usr/bin/git、C:\Program Files\Git\cmd\git.exe) も git とみなす。
    base = re.split(r"[\\/]", word)[-1].lower()
    return base in ("git", "git.exe")


def strip_heredocs(text):
    # ヒアドキュメントの本文 (コミットメッセージやメモ) は実行されないので落とす。
    lines = text.split("\n")
    kept, end = [], None
    for line in lines:
        if end is not None:
            if line.strip() == end:
                end = None
            continue
        kept.append(line)
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", line)
        if m:
            end = m.group(2)
    return "\n".join(kept)


def unquote(m):
    # 引用符の中を落とす。空白を含むもの (メッセージや本文) は 1 語の印に置き換え、
    # 含まないものは外す ("git" -> git)。git のパスを囲んだものは git として残す。
    body = m.group(0)[1:-1]
    if is_git(body):
        return "git"
    return "Q" if re.search(r"\s", body) or body == "" else body


plain = re.sub(r'"(?:\\.|[^"\\])*"|\'[^\']*\'', unquote, strip_heredocs(cmd))

# コマンドの区切りで分け、区切りの中のどこかに git があれば、その後ろのサブコマンドを見る
# (if ... then git push、time git push、PowerShell の if ($?) { git push } なども拾う)。
GLOBAL_WITH_ARG = {"-c", "-C", "--git-dir", "--work-tree", "--namespace", "--config-env", "--exec-path"}
pushing = False
for seg in re.split(r"[;&|(){}\n`!]|\$\(", plain):
    words = seg.split()
    for k, w in enumerate(words):
        if not is_git(w):
            continue
        i = k + 1
        while i < len(words) and words[i].startswith("-"):
            i += 2 if words[i] in GLOBAL_WITH_ARG else 1
        sub = words[i] if i < len(words) else ""
        if sub == "send-pack":
            out("deny", "git send-pack は pre-push を通らない。")
        if sub == "push":
            pushing = True
if not pushing:
    out("allow")

# 決まった形かを見る。空白の連続は 1 つに、空白を含まない引用符は外してから比べる
# (git push origin "work/x" は通す。"--no-verify" のように囲んでも形に合わないので止まる)。
one = re.sub(r'"([^"\s]*)"|\'([^\'\s]*)\'', lambda m: m.group(1) if m.group(1) is not None else m.group(2), cmd.strip())
one = re.sub(r"[ \t]+", " ", one)
ref = r"[A-Za-z0-9._/:+@^~{}][A-Za-z0-9._/:+@^~{}-]*"
form = rf"git push(?: (?:-u|--set-upstream|--force-with-lease(?:={ref})?|--delete|-d|--tags))*(?: origin)?(?: {ref})*(?: 2>&1)?"
if "\n" in one or not re.fullmatch(form, one):
    out("deny", f"決まった形でない git push は通さない (単独の 1 行で、git と push の間に何も挟まない): {cmd.strip()}")
out("check", cwd)
