"""agent-rules/rules.md を、リポジトリの AI エージェント向けのファイルに入れる。

使い方: python3 scripts/apply_agent_rules.py <対象リポジトリのディレクトリ>

- AGENTS.md（opencode など）と .github/copilot-instructions.md（GitHub Copilot）:
  目印の行で囲んだ部分だけを入れるか差し替える。リポジトリ独自のルールはそのまま残す
- CLAUDE.md（Claude Code）: AGENTS.md を読み込む行（@AGENTS.md）がなければ先頭に足す

何度流しても同じ結果になる。変更したファイルのパスを出力する。
"""

import re
import sys
from pathlib import Path

START = "<!-- github-templates:agent-rules:start（github-templates の agent-rules/rules.md から配っている部分。ここは直接直さない） -->"
END = "<!-- github-templates:agent-rules:end -->"
BLOCK = re.compile(r"<!-- github-templates:agent-rules:start.*?-->.*?<!-- github-templates:agent-rules:end -->", re.S)

AGENTS_HEADER = """# AI エージェント向けのルール

Claude Code・GitHub Copilot・opencode など、このリポジトリで作業する AI エージェントに共通のルールです。
（Claude Code は `CLAUDE.md` から、Copilot は `.github/copilot-instructions.md` からこのルールを読みます）
"""

COPILOT_HEADER = """# GitHub Copilot 向けのルール

AI エージェント共通のルールは、リポジトリのルートの `AGENTS.md` にあります。次はその共通部分の写しです。
"""


def with_block(text: str | None, header: str, block: str) -> str:
    if text is None:
        return f"{header}\n{block}\n"
    if BLOCK.search(text):
        return BLOCK.sub(lambda _: block, text, count=1)
    return f"{text.rstrip()}\n\n{block}\n"


def with_import(text: str | None) -> str:
    if text is None:
        return "@AGENTS.md\n"
    if re.search(r"^@AGENTS\.md\s*$", text, re.M):
        return text
    return f"@AGENTS.md\n\n{text}"


def main() -> None:
    target = Path(sys.argv[1])
    rules = (Path(__file__).resolve().parent.parent / "agent-rules" / "rules.md").read_text(encoding="utf-8")
    block = f"{START}\n{rules.strip()}\n{END}"

    def update(relative: str, change) -> None:
        path = target / relative
        before = path.read_text(encoding="utf-8") if path.exists() else None
        after = change(before)
        if after != before:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(after, encoding="utf-8")
            print(relative)

    update("AGENTS.md", lambda t: with_block(t, AGENTS_HEADER, block))
    update(".github/copilot-instructions.md", lambda t: with_block(t, COPILOT_HEADER, block))
    update("CLAUDE.md", with_import)


if __name__ == "__main__":
    main()
