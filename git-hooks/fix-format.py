#!/usr/bin/env python3
"""ステージした内容の、改行コードの混在と BOM の付け外しをコミットの前に直す。

pre-commit から呼ぶ。コミットは止めない (直せないものは知らせるだけで、終了コードは常に 0)。

直すもの:
  - 改行の混在: 1 本のファイルに CRLF と LF が混ざったもの。HEAD の形式に揃える
    (HEAD に無い新しいファイルは多い方に揃える)。混在は意図して作ることが無いので黙って直す。
  - BOM: リポジトリに .github/scripts/bom_policy.py があればその決まりに合わせる。
    無ければ、HEAD で BOM の無かったファイルに付いた BOM だけを外す。

直さないもの:
  - ファイル全体の CRLF <-> LF の変換。意図した変換と区別できないので、知らせるだけにする。
  - git が改行を正規化するファイル (.gitattributes の text / text=auto)。git に任せる。
  - バイナリ (NUL を含むもの、binary 属性のもの)。

ステージの内容 (index) を直し、作業ツリーのファイルがステージと同じ中身なら作業ツリーも直す
(git add -p で一部だけステージしたファイルは、作業ツリーを触らない)。

止めるには:
  git config nox.fixFormat false   … このリポジトリでは直さない
  NOX_FIX_FORMAT=0 git commit ...  … このコミットだけ直さない
"""

import importlib.util
import os
import subprocess
import sys

MAX_SIZE = 16 * 1024 * 1024
BOM = b"\xef\xbb\xbf"


def git(*args, data=None):
    return subprocess.run(["git", *args], input=data, capture_output=True, check=True).stdout


def try_git(*args):
    try:
        return git(*args)
    except subprocess.CalledProcessError:
        return None


def classify(data):
    """改行の形式を "none" / "crlf" / "lf" / "mixed" で返す。"""
    crlf = data.count(b"\r\n")
    lf = data.count(b"\n") - crlf
    if crlf == 0 and lf == 0:
        return "none", crlf, lf
    if lf == 0:
        return "crlf", crlf, lf
    if crlf == 0:
        return "lf", crlf, lf
    return "mixed", crlf, lf


def convert(data, eol):
    data = data.replace(b"\r\n", b"\n")
    return data.replace(b"\n", b"\r\n") if eol == "crlf" else data


def load_bom_policy(top):
    """リポジトリの bom_policy.policy を返す。無い・読めないなら None。"""
    path = os.path.join(top, ".github", "scripts", "bom_policy.py")
    if not os.path.isfile(path):
        return None
    try:
        spec = importlib.util.spec_from_file_location("nox_bom_policy", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.policy
    except Exception as e:  # noqa: BLE001 壊れていても直すのをやめるだけにする
        print(f"pre-commit: bom_policy.py を読めないので BOM は直さない ({e})", file=sys.stderr)
        return None


def staged_paths():
    out = git("diff", "--cached", "--name-only", "--no-renames", "--diff-filter=AM", "-z")
    return [p for p in out.decode("utf-8", "surrogateescape").split("\0") if p]


def attributes(paths):
    """{path: {"text": 値, "binary": 値}}。値は set / unset / unspecified / 文字列。"""
    result = {p: {} for p in paths}
    if not paths:
        return result
    data = "\0".join(paths).encode("utf-8", "surrogateescape") + b"\0"
    out = git("check-attr", "-z", "--stdin", "text", "binary", data=data)
    fields = out.decode("utf-8", "surrogateescape").split("\0")
    for i in range(0, len(fields) - 2, 3):
        path, attr, value = fields[i], fields[i + 1], fields[i + 2]
        if path in result:
            result[path][attr] = value
    return result


def git_normalizes(attr):
    """git が改行を正規化するか (text が set か auto)。"""
    return attr.get("text") in ("set", "auto")


def want_bom(path, policy, head, staged):
    """BOM を付けるべきなら True、外すべきなら False、触らないなら None。"""
    if policy is not None:
        decision = policy(path)
        if decision == "required":
            return True
        if decision == "forbidden":
            return False
        return None
    if head is not None and not head.startswith(BOM) and staged.startswith(BOM):
        return False
    return None


def fix(path, staged, head, attr, policy):
    """直した内容と、何を直したかの説明のリストを返す。"""
    notes = []
    data = staged

    bom = want_bom(path, policy, head, data)
    if bom is True and not data.startswith(BOM):
        data = BOM + data
        notes.append("BOM を付けた")
    elif bom is False and data.startswith(BOM):
        data = data[len(BOM):]
        notes.append("BOM を外した")

    if not git_normalizes(attr):
        fmt, crlf, lf = classify(data)
        head_fmt = classify(head)[0] if head is not None else "none"
        if fmt == "mixed":
            if head_fmt in ("crlf", "lf"):
                target = head_fmt
            else:
                target = "crlf" if crlf >= lf else "lf"
            data = convert(data, target)
            notes.append(f"混在していた改行を {target.upper()} に揃えた (CRLF {crlf} 行 / LF {lf} 行)")
        elif fmt in ("crlf", "lf") and head_fmt in ("crlf", "lf") and fmt != head_fmt:
            print(
                f"pre-commit: {path}: 改行が全体で {head_fmt.upper()} -> {fmt.upper()} に変わっている。"
                "意図した変換でなければ戻すこと (直していない)",
                file=sys.stderr,
            )

    return data, notes


def is_partial_commit():
    """git commit <パス> か。git はこのときだけ仮の index (next-index-*.lock) でコミットを作り、
    本来の index はコミットの間ロックして後から書き戻す。フックからは本来の index を直せないので、
    コミットと作業ツリーは直るが、本来の index に直す前の中身が残る (status が MM になる)。
    残ったものは、次のコミットでこのフックがまた直す。"""
    return os.path.basename(os.environ.get("GIT_INDEX_FILE", "")).startswith("next-index")


def main():
    if os.environ.get("NOX_FIX_FORMAT") == "0":
        return 0
    if (try_git("config", "--bool", "nox.fixFormat") or b"").strip() == b"false":
        return 0

    top = git("rev-parse", "--show-toplevel").decode("utf-8", "surrogateescape").strip()
    os.chdir(top)
    has_head = try_git("rev-parse", "--verify", "-q", "HEAD") is not None

    paths = staged_paths()
    attrs = attributes(paths)
    policy = load_bom_policy(top)

    fixed_any = False
    for path in paths:
        try:
            attr = attrs.get(path, {})
            if attr.get("binary") == "set":
                continue

            entry = git("ls-files", "-s", "-z", "--", path).decode("utf-8", "surrogateescape").split("\0")[0]
            if not entry:
                continue
            mode, sha = entry.split(" ")[0], entry.split(" ")[1]
            if mode == "120000" or mode == "160000":  # シンボリックリンクとサブモジュール
                continue
            if int(git("cat-file", "-s", sha).strip()) > MAX_SIZE:
                continue

            staged = git("cat-file", "blob", sha)
            if b"\0" in staged:
                continue
            head = try_git("cat-file", "blob", f"HEAD:{path}") if has_head else None

            fixed, notes = fix(path, staged, head, attr, policy)
            if fixed == staged:
                continue

            new_sha = git("hash-object", "-w", "--no-filters", "--stdin", data=fixed).decode().strip()
            git("update-index", "--cacheinfo", f"{mode},{new_sha},{path}")
            fixed_any = True

            # 作業ツリーがステージと同じ中身のときだけ、作業ツリーも直す
            worktree_note = ""
            try:
                with open(path, "rb") as f:
                    current = f.read()
                if current == staged:
                    with open(path, "wb") as f:
                        f.write(fixed)
                else:
                    worktree_note = " (作業ツリーはステージと違うので触っていない)"
            except OSError:
                worktree_note = " (作業ツリーのファイルを読めなかった)"

            print(f"pre-commit: {path}: {'、'.join(notes)}{worktree_note}", file=sys.stderr)
        except Exception as e:  # noqa: BLE001 1 本で失敗しても、ほかは続けてコミットも止めない
            print(f"pre-commit: {path}: 改行と BOM を直せなかった ({e})", file=sys.stderr)

    if fixed_any and is_partial_commit():
        print("pre-commit: git commit <パス> ではステージに直す前の内容が残る。git add <パス> で揃う", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001 コミットは止めない
        print(f"pre-commit: 改行と BOM の修正を飛ばした ({e})", file=sys.stderr)
        sys.exit(0)
