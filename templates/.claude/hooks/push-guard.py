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
ESC = "`" if ps else "\\"
COMMENT_AFTER = ("", " ", "\t", "\n", ";", "&", "|", "(", ")")


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


def lex(text, i=0, stop=False):
    """実行されない部分 (引用符の中の文、コメント、ヒアドキュメントの本文) を落とし、コマンドの語だけを残す。

    引用符の中は、空白を含むもの (メッセージや本文) を 1 語の印 Q に、含まないものは外す ("git" -> git)。
    引用符の中のコマンド置換 ("$(...)"、"`...`") と、シェルに渡して実行するもの (bash -c "..."、eval "...") は、
    中身をコマンドとして読み、末尾に別の行として足す (元の位置には Q を置くので、git と push の間は崩れない)。
    stop が真なら、対応する ) まで読んで (結果, ) の次の位置) を返す。
    """
    buf, side, pending = [], [], []
    n, arith, depth = len(text), 0, 0

    def words_here():
        # 組み立て中の出力の、いまの区切りの語 (直前の部分だけを見る)。
        return re.split(SEP, "".join(buf[-200:]))[-1].split()

    def emit(raw, literal, code):
        words = words_here()
        prev = words[-1].lower() if words else ""
        runs = (prev in ("eval", "invoke-expression", "iex")
                or (re.fullmatch(r"-[a-z]*c|/c|/k|-command", prev) and any(is_shell(w) for w in words[:-1])))
        if runs:
            side.append(lex(raw)[0])
            buf.append("Q")
            return
        side.extend(code)
        if is_git(literal) and not code:
            buf.append("git")
        elif literal == "" or code or re.search(r"\s", literal):
            buf.append("Q")
        else:
            buf.append(literal)

    def dquote(j):
        # j は開きの " の次。閉じの " の次の位置と、(中身そのまま, 地の文, 置換の中身) を返す。閉じが無ければ None。
        lit, code, start = [], [], j
        while j < n:
            ch = text[j]
            if ch == ESC:
                lit.append(text[j + 1:j + 2])
                j += 2
                continue
            if ch == '"':
                if ps and text[j + 1:j + 2] == '"':
                    lit.append('"')
                    j += 2
                    continue
                return j + 1, text[start:j], "".join(lit), code
            if text.startswith("$(", j) and not text.startswith("$((", j):
                inner, j = lex(text, j + 2, True)
                code.append(inner)
                continue
            if not ps and ch == "`":
                e = j + 1
                while e < n and text[e] != "`":
                    e += 2 if text[e] == "\\" else 1
                code.append(lex(text[j + 1:e])[0])
                j = e + 1
                continue
            lit.append(ch)
            j += 1
        return None

    def done(at):
        return "".join(buf) + "".join("\n" + s + "\n" for s in side), at

    while i < n:
        c = text[i]
        if c == "\n":
            buf.append("\n")
            i += 1
            if pending:
                i = skip_bodies(text, i, pending)
                pending = []
            continue
        if c == ESC and i + 1 < n:
            buf.append(" " if text[i + 1] == "\n" else text[i + 1])
            i += 2
            continue
        if ps and text.startswith("<#", i):
            j = text.find("#>", i + 2)
            i = n if j < 0 else j + 2
            buf.append(" ")
            continue
        if c == "#" and (not buf or buf[-1][-1:] in COMMENT_AFTER):
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
        if stop and c == "(":
            depth += 1
        if stop and c == ")":
            if depth == 0:
                return done(i + 1)
            depth -= 1
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
                words = words_here()
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
                body = text[i + 2:j]
                emit(body, body, [lex(body)[0]] if q == '"' and "$(" in body else [])
                i = j + 3
                continue
        if not ps and c == "$" and text[i + 1:i + 2] == "'":
            j = i + 2
            while j < n and text[j] != "'":
                j += 2 if text[j] == "\\" else 1
            if j < n:
                body = text[i + 2:j]
                emit(body, body, [])
                i = j + 1
                continue
        if c == "'":
            j = text.find("'", i + 1)
            if j >= 0:
                body = text[i + 1:j]
                emit(body, body, [])
                i = j + 1
                continue
        if c == '"':
            r = dquote(i + 1)
            if r:
                i, raw, literal, code = r
                emit(raw, literal, code)
                continue
        buf.append(c)
        i += 1
    return done(n)


plain = lex(cmd)[0]

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
