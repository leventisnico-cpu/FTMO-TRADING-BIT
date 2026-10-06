"""Every text file read/write names its encoding.

Windows defaults to cp1252, which cannot encode characters the reports use
(e.g. "→"), so an implicit encoding crashes there while passing on Linux.
Ruff's PLW1514 misses ``Path.write_text``; this AST scan covers it.
"""

from __future__ import annotations

import ast
from pathlib import Path

import ftmo_bot

TEXT_IO = {"read_text", "write_text", "open"}


def _mode(call: ast.Call) -> str:
    """The mode string: keyword, or the positional arg that looks like one
    (first for ``Path.open``, second for builtin ``open``)."""
    for kw in call.keywords:
        if kw.arg == "mode" and isinstance(kw.value, ast.Constant):
            return str(kw.value.value)
    for arg in call.args[:2]:
        v = arg.value if isinstance(arg, ast.Constant) else None
        if isinstance(v, str) and v and set(v) <= set("rwxabt+"):
            return v
    return "r"


def _missing_encoding(path: Path) -> list[str]:
    bad = []
    for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
        if name not in TEXT_IO:
            continue
        if name == "open" and "b" in _mode(node):
            continue
        if not any(kw.arg == "encoding" for kw in node.keywords):
            bad.append(f"{path.name}:{node.lineno} {name}()")
    return bad


def test_all_text_io_names_an_encoding() -> None:
    roots = [Path(ftmo_bot.__file__).parent, Path(__file__).parent]
    bad = [b for root in roots for p in sorted(root.rglob("*.py")) for b in _missing_encoding(p)]
    assert bad == [], bad


def test_scanner_catches_the_windows_bug(tmp_path: Path) -> None:
    sample = tmp_path / "sample.py"
    sample.write_text(
        "from pathlib import Path\n"
        "Path('a').write_text('→')\n"
        "Path('b').write_text('x', encoding='utf-8')\n"
        "open('c', 'rb')\n",
        encoding="utf-8",
    )
    assert _missing_encoding(sample) == ["sample.py:2 write_text()"]
