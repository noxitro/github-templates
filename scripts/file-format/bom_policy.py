"""どのファイルに UTF-8 BOM を付けるかの決まり (既定)。check-file-format.py と strip-bom.py が使う。

リポジトリごとに変えたいときは、templates/.github/scripts/bom_policy.py を対象のリポジトリの
.github/scripts/bom_policy.py に写して直す。そちらがあればこのファイルより優先する。

テキストファイルは BOM なしの UTF-8 に統一する。BOM が要るのは、BOM が無いとシステムの
コードページ (日本語 Windows では Shift-JIS) で読まれてしまう次のものだけ。
.editorconfig の charset もこれと揃えること。
"""

import fnmatch

# BOM が必要なもの
REQUIRED = [
    # Windows PowerShell 5.1 は BOM の無いスクリプトを Shift-JIS として読む
    "*.ps1",
    "*.psm1",
    "*.psd1",
]

# どちらでもよいもの (移行中)
ANY = []

REQUIRED_POLICY = "required"
FORBIDDEN_POLICY = "forbidden"
ANY_POLICY = "any"


def policy(path):
    """path (リポジトリのルートからの / 区切りのパス) の BOM の決まりを返す。"""
    if any(fnmatch.fnmatch(path, p) for p in REQUIRED):
        return REQUIRED_POLICY
    if any(fnmatch.fnmatch(path, p) for p in ANY):
        return ANY_POLICY
    return FORBIDDEN_POLICY
