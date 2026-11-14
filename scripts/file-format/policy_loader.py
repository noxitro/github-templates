"""BOM の決まり (bom_policy) を読み込む。

検査するリポジトリ (カレントディレクトリの git のルート) に .github/scripts/bom_policy.py が
あればそれを、無ければこのファイルの隣の bom_policy.py を使う。
"""

import importlib.util
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _repo_root():
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"], check=True,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return out.decode("utf-8", "replace").strip() or None


def _load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_bom_policy():
    default = _load(os.path.join(HERE, "bom_policy.py"), "default_bom_policy")
    root = _repo_root()
    if root:
        local = os.path.join(root, ".github", "scripts", "bom_policy.py")
        if os.path.isfile(local) and os.path.abspath(local) != os.path.join(HERE, "bom_policy.py"):
            print(f"BOM の決まり: {os.path.relpath(local, root)}", file=sys.stderr)
            module = _load(local, "repo_bom_policy")
            # 古い写しや policy() だけを書いたものでも動くよう、定数は既定で補う
            for name in ("REQUIRED_POLICY", "FORBIDDEN_POLICY", "ANY_POLICY"):
                if not hasattr(module, name):
                    setattr(module, name, getattr(default, name))
            return module
    return default
