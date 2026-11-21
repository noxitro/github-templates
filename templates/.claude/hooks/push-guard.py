# push-guard.sh から呼ぶ判定の本体。入力 (フックの JSON) は標準入力で受け取る。
# 結果は標準出力に、1 行目が allow / deny / check、2 行目以降が理由 (deny) か作業ディレクトリ (check)。
import json
import re
import sys

# 作業ディレクトリに日本語などが入っていても、呼び出し側 (bash) が読める形で返す。改行は LF に揃える。
sys.stdout.reconfigure(encoding="utf-8", newline="\n")

d = json.loads(sys.stdin.buffer.read().decode("utf-8"))
tool = d.get("tool_name") or ""
cmd = (d.get("tool_input") or {}).get("command") or ""
cwd = d.get("cwd") or ""


def out(*lines):
    sys.stdout.write("\n".join(lines))
    sys.exit(0)


# MCP: GitHub の API でファイルやコミットを直接書くツール。名前だけで GitHub のものと分かるものはどのサーバーでも止め、
# ほかのサーバーにもありうる名前 (delete_file / update_file) は、サーバー名に github を含むときだけ止める。
if tool.startswith("mcp__"):
    parts = tool.split("__")
    server, name = (parts[1] if len(parts) > 2 else ""), parts[-1]
    if (re.search(r"push_files|create_or_update_file|create_commit|commit_files", name, re.I)
            or ("github" in server.lower() and re.search(r"delete_file|update_file", name, re.I))):
        out("deny", f"{tool} は GitHub の API でファイルやコミットを直接書くので、pre-push の検査を通らない。")
    out("allow")
if tool not in ("Bash", "PowerShell"):
    out("allow")
ps = tool == "PowerShell"

# gh api でのファイル・コミットの書き込み (git のフックを通らない)。
if (re.search(r"(^|[^\w-])gh\s+api(\s|$)", cmd) and re.search(r"/(contents|git)/", cmd)
        and re.search(r"(-X|--method)[\s=]*(PUT|POST|PATCH|DELETE)|(^|\s)(-f|-F|--field|--raw-field|--input)([\s=]|$)", cmd)):
    out("deny", "gh api でのファイル・コミットの書き込みは pre-push を通らない。")


def base(word):
    return re.split(r"[\\/]", word)[-1].lower()


def is_git(word):
    # パスで書いた git (/usr/bin/git、C:\Program Files\Git\cmd\git.exe) も git とみなす。
    return base(word) in ("git", "git.exe")


def is_shell(word):
    b = base(word)
    return (b[:-4] if b.endswith(".exe") else b) in ("bash", "sh", "zsh", "dash", "ksh", "pwsh", "powershell", "cmd")


SEP = r"[;&|(){}\n`!]|\$\("


def seg_words(buf):
    # 組み立て中の出力の、いまの区切りの語。
    return re.split(SEP, "".join(buf))[-1].split()


def skip_bodies(text, i, pending):
    # ヒアドキュメントの本文を飛ばした先の位置を返す。終わりの行が見つからなければ飛ばさない (落とさずに読む)。
    start = i
    for delim, tabs in pending:
        while True:
            e = text.find("\n", i)
            line = (text[i:] if e < 0 else text[i:e]).rstrip("\r")
            if (line.lstrip("\t") if tabs else line) == delim:
                i = len(text) if e < 0 else e + 1
                break
            if e < 0:
                return start
            i = e + 1
    return i


def flatten(text):
    # 実行されない部分 (引用符の中の文、コメント、ヒアドキュメントの本文) を落とし、コマンドの語だけを残す。
    # 引用符の中は、空白を含むもの (メッセージや本文) を 1 語の印 Q に、含まないものは外す ("git" -> git)。
    # ただし、シェルに渡して実行するもの (bash -c "..."、bash <<EOF、"$(...)" など) は中身もコマンドとして読む。
    esc = "`" if ps else "\\"
    buf, pending = [], []
    i, n, arith = 0, len(text), 0

    def emit(body, double):
        words = seg_words(buf)
        prev = words[-1].lower() if words else ""
        runs = (prev in ("eval", "invoke-expression", "iex")
                or (re.fullmatch(r"-[a-z]*c|/c|/k|-command", prev) and any(is_shell(w) for w in words[:-1])))
        if runs or (double and ("$(" in body or (not ps and "`" in body))):
            buf.append(" ; " + flatten(body) + " ; ")
        elif is_git(body):
            buf.append("git")
        elif body == "" or re.search(r"\s", body):
            buf.append("Q")
        else:
            buf.append(body)

    while i < n:
        c = text[i]
        if c == "\n":
            buf.append("\n")
            i += 1
            if pending:
                i = skip_bodies(text, i, pending)
                pending = []
            continue
        if c == esc and i + 1 < n:
            buf.append(" " if text[i + 1] == "\n" else text[i + 1])
            i += 2
            continue
        if ps and text.startswith("<#", i):
            j = text.find("#>", i + 2)
            i = n if j < 0 else j + 2
            buf.append(" ")
            continue
        if c == "#" and (not buf or buf[-1][-1:] in ("", " ", "\t", "\n", ";", "&", "|", "(", ")", "{", "}")):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if not ps and text.startswith("$((", i):
            arith += 1
            buf.append("$((")
            i += 3
            continue
        if arith and text.startswith("))", i):
            arith -= 1
            buf.append("))")
            i += 2
            continue
        if (not ps and not arith and text.startswith("<<", i) and not text.startswith("<<<", i)
                and not (buf and buf[-1].endswith("<"))):
            j = i + 2
            tabs = j < n and text[j] == "-"
            j += 1 if tabs else 0
            while j < n and text[j] in " \t":
                j += 1
            m = re.match(r"""(?:[^\s;&|()<>'"\\]|'[^'\n]*'|"[^"\n]*"|\\.)+""", text[j:])
            if m:
                delim = re.sub(r"""['"\\]""", "", m.group(0))
                words = seg_words(buf)
                to_shell = bool(words) and (is_shell(words[-1]) or (len(words) > 1 and is_shell(words[-2]) and words[-1] == "-s"))
                if delim and not to_shell:
                    pending.append((delim, tabs))
                buf.append(" <<H ")
                i = j + m.end()
                continue
        if ps and c == "@" and text[i + 1:i + 2] in ("'", '"'):
            q = text[i + 1]
            j = text.find("\n" + q + "@", i + 2)
            if j >= 0:
                emit(text[i + 2:j], q == '"')
                i = j + 3
                continue
        if c == "'":
            j = text.find("'", i + 1)
            if j < 0:
                buf.append(c)
                i += 1
                continue
            emit(text[i + 1:j], False)
            i = j + 1
            continue
        if c == '"':
            j = i + 1
            while j < n:
                if text[j] == esc:
                    j += 2
                    continue
                if text[j] == '"':
                    if ps and text[j + 1:j + 2] == '"':
                        j += 2
                        continue
                    break
                j += 1
            if j >= n:
                buf.append(c)
                i += 1
                continue
            emit(text[i + 1:j], True)
            i = j + 1
            continue
        buf.append(c)
        i += 1
    return "".join(buf)


plain = flatten(cmd)

# コマンドの区切りで分け、区切りの中のどこかに git があれば、その後ろのサブコマンドを見る
# (if ... then git push、time git push、PowerShell の if ($?) { git push } なども拾う)。
GLOBAL_WITH_ARG = {"-c", "-C", "--git-dir", "--work-tree", "--namespace", "--config-env", "--exec-path"}
pushing = need_check = False
for seg in re.split(SEP, plain):
    words = seg.split()
    for k, w in enumerate(words):
        # gh repo create --push は内部で git push する。フックが入った環境かだけを確かめる。
        if (base(w) in ("gh", "gh.exe") and words[k + 1:k + 3] == ["repo", "create"]
                and any(x == "--push" or x.startswith("--push=") for x in words[k + 3:])):
            need_check = True
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
        if sub == "subtree" and "push" in words[i + 1:]:
            if i != k + 1:
                out("deny", "git と subtree の間にオプションを挟んだ git subtree push は通さない。")
            need_check = True

if pushing:
    # 決まった形かを見る。空白の連続は 1 つに、空白を含まない引用符は外してから比べる
    # (git push origin "work/x" は通す。"--no-verify" のように囲んでも形に合わないので止まる)。
    # オプションは下のものだけで、ブランチとの順番は問わない (ブランチ名は - で始まらない)。
    one = re.sub(r'"([^"\s]*)"|\'([^\'\s]*)\'', lambda m: m.group(1) if m.group(1) is not None else m.group(2), cmd.strip())
    one = re.sub(r"[ \t]+", " ", one)
    ref = r"[A-Za-z0-9._/:+@^~{}][A-Za-z0-9._/:+@^~{}-]*"
    opt = rf"-u|--set-upstream|--force-with-lease(?:={ref})?|--delete|-d|--tags|--follow-tags"
    form = rf"git push(?: (?:{opt}|{ref}))*(?: 2>&1)?"
    if "\n" in one or not re.fullmatch(form, one):
        out("deny", f"決まった形でない git push は通さない (単独の 1 行で、git と push の間に何も挟まない): {cmd.strip()}")
    out("check", cwd)
if need_check:
    out("check", cwd)
out("allow")
