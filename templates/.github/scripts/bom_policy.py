"""どのファイルに UTF-8 BOM を付けるかの決まり。

noxitro/github-templates の file-format.yml (check-file-format.py)・strip-bom.py・git-hooks の
fix-format.py が使う。file-format.yml と strip-bom.py は、無ければ同じ内容の既定を使う。
fix-format.py (pre-commit) は、このファイルが無いと「HEAD で BOM の無かったファイルに付いた BOM を
外す」ことしかしない (*.ps1 に BOM を付けるにはこのファイルが要る)。

テキストファイルは BOM なしの UTF-8 に統一する。BOM が要るのは、BOM が無いとシステムの
コードページ (日本語 Windows では Shift-JIS) で読まれてしまうものだけ。
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

# どちらでもよいもの
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
