#!/usr/bin/env python3
"""外部資料 (発表・書籍・他社の製品や設計) の名前がリポジトリへ入るのを止める。

名前そのものをこのリポジトリに書くと、検査の仕組みが漏えい元になる。
そのため禁止する名前は external-names.sha256 にハッシュで置き、
本文から切り出した候補語をハッシュして突き合わせる。

照合は 2 種類ある。どちらも NFKC 正規化して小文字にしてから行う。

  語として照合 (名前が英数字とカタカナだけのとき。リストの行はハッシュのみ):
    英数字の並びとカタカナの並びを語として取り出す。間が語の文字以外 3 文字以内
    (空白・記号) で続く語は最大 3 語までつなげて 1 つの候補にもする。
    "Foo-Bar" "foo_bar" "FooBar" "foo bar" "Foo's Bar" はどれも同じ候補になる。
    語の境界を見るので、長い単語の一部に偶然含まれても誤検出しない。
    この規則で拾えない名前 (4 文字未満・4 語以上など) は --hash が登録を拒む。

  部分文字列として照合 (漢字・ひらがなを含むとき。リストの行は "ハッシュ 文字数"):
    日本語には語の区切りが無いので、漢字・ひらがなを含む行だけを対象に、
    文字以外 (空白・記号) を除いた並びから登録済みの文字数の窓を切り出して照合する。

  登録 (--hash) と検出は同じ正規化 (compact) を使う。

ハッシュは総当たりで元に戻せる。目的は「名前を平文で置かない」ことであって、
秘密にすることではない。

リポジトリの外に置く非公開リストも併せて見る (既定 ~/.config/nox/private-names.sha256、
環境変数 NOX_PRIVATE_NAMES で変えられる)。所属先など、ハッシュでもリポジトリに置くと
候補の総当たりで関係が知られてしまう名前はこちらへ入れる。書式は禁止リストと同じで、
--add-private で追記できる。無ければ飛ばす (CI には無いので、止めるのは手元のフックだけ)。

使い方:
  check-external-names.py --blobs          標準入力の "<path>\\t<blob-ish>" を検査 (scan.sh と同じ形式)
  check-external-names.py --message FILE   コミットメッセージを検査 (commit-msg フック)
  check-external-names.py --commits REV... 範囲内のコミットメッセージを検査 (pre-push / CI)
  check-external-names.py --hash NAME...   禁止リストへ足す行を出力する
  check-external-names.py --add-private NAME...   非公開リストへ追記する (名前は画面にも出さない)

  --list FILE で禁止リストを指定できる (複数可)。省略時は隣の external-names.sha256。

検出したら場所を表示して終了コード 1 を返す。一致した語は伏せ字で出す
(CI のログは公開されるため)。
"""
from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import re
import subprocess
import sys
import threading
import unicodedata
from collections.abc import Iterator

HERE = pathlib.Path(__file__).resolve().parent
LIST_PATH = HERE / "external-names.sha256"
PRIVATE_LIST_PATH = pathlib.Path(
    os.environ.get("NOX_PRIVATE_NAMES") or pathlib.Path.home() / ".config" / "nox" / "private-names.sha256")
SALT = "nox-external-name:"
MAX_BYTES = 5 * 1024 * 1024
MAX_JOIN = 3

# 名前ではないが、外部資料からの引き写しを示す語。平文で置いてよい。
HINT_TERMS = ("講演",)

# 検査の仕組み自身。HINT_TERMS を平文で持つので対象から外す。
# github-templates では git-hooks/、共通化する前の Nox では tools/git-hooks/ にあるので末尾で見る。
# 禁止リスト (external-names.sha256) は平文の名前を持たないはずなので、外さずに検査する。
SELF_SUFFIX = "git-hooks/check-external-names.py"

TOKEN_RE = re.compile(r"[0-9a-z]+|[ァ-ヺー]+")
TOKEN_ONLY_RE = re.compile(r"(?:[0-9a-z]|[ァ-ヺー])+")
# 語と語の間に挟まってよいもの。語の文字 (英数字・カタカナ) 以外なら何でも 3 文字まで。
# 登録時の compact() は語の文字以外を全部落とすので、ここを絞ると登録できても検出できない名前が出る。
GAP_RE = re.compile(r"[^0-9a-zァ-ヺー\n]{0,3}")
MIN_TOKEN_LEN = 4
# 部分文字列照合を行う行の目印 (ひらがな・漢字)。
CJK_RE = re.compile(r"[ぁ-ゖ\u3400-\u9fff\uf900-\ufaff]")


class NameList:
    """禁止リスト。語として照合するものと、部分文字列として照合するもの。"""

    def __init__(self) -> None:
        self.tokens: set[str] = set()
        self.substrings: set[str] = set()
        self.lengths: set[int] = set()

    def load(self, path: pathlib.Path) -> None:
        for line in path.read_text(encoding="utf-8").splitlines():
            fields = line.split("#", 1)[0].split()
            if not fields:
                continue
            if len(fields) == 1:
                self.tokens.add(fields[0].lower())
            else:
                self.substrings.add(fields[0].lower())
                self.lengths.add(int(fields[1]))


def digest(word: str) -> str:
    return hashlib.sha256((SALT + word).encode("utf-8")).hexdigest()


def normalize(text: str) -> str:
    return unicodedata.normalize("NFKC", text).lower()


def compact(norm: str) -> str:
    """正規化済みの文字列から文字 (英数字・かな・漢字) 以外を除く。登録と検出で共有する。"""
    return "".join(ch for ch in norm if ch.isalnum())


def list_entry(name: str) -> str:
    """--hash の出力 1 行。

    出力した行で名前そのものが検出できることを確かめてから返す。語の数が MAX_JOIN を
    超える、語の間の区切りが長すぎる、短すぎるなど、検出側の規則で拾えない名前を
    黙って登録させないため。
    """
    word = compact(normalize(name))
    if not word:
        raise ValueError(f"文字を含まない名前は登録できない: {name!r}")
    if TOKEN_ONLY_RE.fullmatch(word):
        entry = digest(word)
        names = NameList()
        names.tokens.add(entry)
    else:
        entry = f"{digest(word)} {len(word)}"
        names = NameList()
        names.substrings.add(digest(word))
        names.lengths.add(len(word))
    if find_in_line(name, names, hints=False) is None:
        raise ValueError(
            f"この名前は登録しても検出できない: {name!r} "
            f"(英数字・カタカナの名前は {MIN_TOKEN_LEN} 文字以上、{MAX_JOIN} 語以内、語の間の区切りは 3 文字以内)")
    return entry


def mask(word: str) -> str:
    return word[:1] + "*" * (len(word) - 1)


def find_in_line(line: str, names: NameList, hints: bool = True) -> str | None:
    """行の中で最初に見つかった禁止語 (伏せ字) を返す。"""
    norm = normalize(line)
    for term in HINT_TERMS if hints else ():
        if term in norm:
            return term
    if names.substrings and CJK_RE.search(norm):
        text = compact(norm)
        for n in names.lengths:
            for i in range(len(text) - n + 1):
                window = text[i:i + n]
                if digest(window) in names.substrings:
                    return mask(window)
    hashes = names.tokens
    tokens = list(TOKEN_RE.finditer(norm))
    for i, first in enumerate(tokens):
        word = first.group()
        end = first.end()
        for j in range(i, min(i + MAX_JOIN, len(tokens))):
            if j > i:
                nxt = tokens[j]
                if not GAP_RE.fullmatch(norm, end, nxt.start()):
                    break
                word += nxt.group()
                end = nxt.end()
            if len(word) >= MIN_TOKEN_LEN and digest(word) in hashes:
                return mask(word)
    return None


class Checks:
    """照合するリストの組。公開の禁止リストと、手元にだけある非公開リスト。"""

    def __init__(self, names: NameList, private: NameList | None) -> None:
        self.names = names
        self.private = private


def scan_text(label: str, text: str, checks: Checks) -> int:
    found = 0
    for no, line in enumerate(text.splitlines(), 1):
        hit = find_in_line(line, checks.names)
        if hit:
            print(f"  [EXTERNAL-NAME] {label}:{no}\n    {hit} — 外部資料の名前 / 外部資料への言及", file=sys.stderr)
            found += 1
            continue
        if checks.private is not None:
            hit = find_in_line(line, checks.private, hints=False)
            if hit:
                print(f"  [PRIVATE-NAME] {label}:{no}\n    {hit} — 手元の非公開リストの名前 (所属先など)", file=sys.stderr)
                found += 1
    return found


def iter_blobs(pairs: list[tuple[str, str]]) -> Iterator[tuple[str, bytes]]:
    """git cat-file --batch 1 本で順に読む。

    出力は 1 blob ずつ読み出して手放すので、初回 push で全ファイルが流れてきても
    同時に抱えるのは 1 blob 分だけになる。上限を超える blob は読み飛ばして本文を持たない。
    """
    if not pairs:
        return
    proc = subprocess.Popen(["git", "cat-file", "--batch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    assert proc.stdin is not None and proc.stdout is not None

    # 入力を書き切る前に出力のパイプが詰まると互いに待つので、書き込みは別スレッドで行う。
    def feed() -> None:
        try:
            for _, obj in pairs:
                proc.stdin.write(obj.encode("utf-8") + b"\n")
        except BrokenPipeError:
            pass  # git が先に終わった。読み側で途切れとして扱う
        finally:
            try:
                proc.stdin.close()
            except BrokenPipeError:
                pass

    writer = threading.Thread(target=feed, daemon=True)
    writer.start()
    out = proc.stdout
    truncated = False
    for path, _ in pairs:
        header = out.readline().split()
        if not header:
            truncated = True
            break
        if len(header) < 3 or header[1] == b"missing":
            continue
        size = int(header[2])
        if header[1] != b"blob" or size > MAX_BYTES:
            # 本文は持たずに読み飛ばす。途中で出力が尽きたら (git の異常終了) 抜ける。
            while size > 0:
                chunk = out.read(min(size, 1 << 20))
                if not chunk:
                    truncated = True
                    break
                size -= len(chunk)
            if truncated:
                break
            out.read(1)
            continue
        body = out.read(size)
        if len(body) != size:
            truncated = True
            break
        out.read(1)
        yield path, body
    out.close()
    writer.join()
    code = proc.wait()
    # 途中で切れたのに成功扱いにすると、検査しなかったファイルを素通りさせてしまう。
    if truncated or code != 0:
        raise RuntimeError(f"git cat-file --batch が途中で終了した (終了コード {code})")


def cmd_blobs(names: Checks) -> int:
    pairs = []
    for line in sys.stdin.read().splitlines():
        path, sep, obj = line.partition("\t")
        if sep and path and path != SELF_SUFFIX and not path.endswith("/" + SELF_SUFFIX):
            pairs.append((path, obj))
    found = 0
    for path, body in iter_blobs(pairs):
        if b"\0" in body[:8192]:
            continue
        found += scan_text(path, body.decode("utf-8", errors="replace"), names)
    return found


def cmd_message(path: str, names: Checks) -> int:
    text = pathlib.Path(path).read_text(encoding="utf-8", errors="replace")
    # git commit -v の差分や # で始まるコメントは記録されないので見ない。
    text = text.split("# ------------------------ >8 ------------------------", 1)[0]
    text = "\n".join(line for line in text.splitlines() if not line.startswith("#"))
    return scan_text("コミットメッセージ", text, names)


def cmd_commits(rev_range: list[str], names: Checks) -> int:
    out = subprocess.run(["git", "log", "--format=%H%x00%B%x01", *rev_range],
                         capture_output=True, check=True).stdout.decode("utf-8", errors="replace")
    found = 0
    for entry in out.split("\x01"):
        sha, sep, body = entry.strip("\n").partition("\x00")
        if sep:
            found += scan_text(f"コミット {sha[:10]} のメッセージ", body, names)
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--blobs", action="store_true")
    group.add_argument("--message")
    group.add_argument("--commits", nargs=argparse.REMAINDER, metavar="REV")
    group.add_argument("--hash", nargs="+", metavar="NAME")
    group.add_argument("--add-private", nargs="+", metavar="NAME")
    parser.add_argument("--list", action="append", type=pathlib.Path, metavar="FILE")
    args = parser.parse_args()

    if args.hash:
        try:
            for name in args.hash:
                print(list_entry(name))
        except ValueError as e:
            print(e, file=sys.stderr)
            return 2
        return 0

    if args.add_private:
        try:
            entries = [list_entry(name) for name in args.add_private]
        except ValueError as e:
            print(e, file=sys.stderr)
            return 2
        PRIVATE_LIST_PATH.parent.mkdir(parents=True, exist_ok=True)
        text = ""
        if PRIVATE_LIST_PATH.exists():
            text = PRIVATE_LIST_PATH.read_text(encoding="utf-8")
        existing = set(text.splitlines())
        added = [e for e in entries if e not in existing]
        with PRIVATE_LIST_PATH.open("a", encoding="utf-8", newline="\n") as f:
            # 手で編集して末尾の改行が無いと、追記した行が最後の行にくっついてどちらも読めなくなる
            if added and text and not text.endswith("\n"):
                f.write("\n")
            for entry in added:
                f.write(entry + "\n")
        print(f"{PRIVATE_LIST_PATH} に {len(added)} 件足した (既にあったもの {len(entries) - len(added)} 件)")
        return 0

    names = NameList()
    for path in args.list or [LIST_PATH]:
        names.load(path)
    private = None
    if os.environ.get("NOX_PRIVATE_NAMES") and not PRIVATE_LIST_PATH.exists():
        # 既定の場所に無いのは「使っていない」だが、環境変数で明示したのに無いのは設定の誤り。
        # 黙って飛ばすと検査が抜けたことに気付けない。
        print(f"check-external-names: NOX_PRIVATE_NAMES の指すファイルが無い: {PRIVATE_LIST_PATH}", file=sys.stderr)
        return 2
    if PRIVATE_LIST_PATH.exists():
        private = NameList()
        private.load(PRIVATE_LIST_PATH)
    names = Checks(names, private)
    try:
        if args.blobs:
            found = cmd_blobs(names)
        elif args.message:
            found = cmd_message(args.message, names)
        else:
            found = cmd_commits(args.commits, names)
    except (RuntimeError, subprocess.CalledProcessError) as e:
        print(f"check-external-names: 検査を完了できなかった: {e}", file=sys.stderr)
        return 2

    if found:
        print(
            "\n  外部資料の名前や、手元の非公開リストの名前 (所属先など) は書かないこと。\n"
            "  設計の説明は資料名を出さずに自分の言葉で書く。\n"
            "  コミットメッセージなら書き直してから push する (git commit --amend / rebase)。",
            file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
