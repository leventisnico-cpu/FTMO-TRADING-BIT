"""PowerShell scripts stay plain ASCII.

Windows PowerShell 5.1 reads BOM-less .ps1 files as ANSI, so any non-ASCII
character (an em dash, an arrow) can turn into mojibake or a parse error on the
user's machine while looking fine everywhere else.
"""

from __future__ import annotations

from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


def test_powershell_scripts_are_ascii() -> None:
    offenders = []
    for path in sorted(SCRIPTS.glob("*.ps1")):
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not line.isascii():
                offenders.append(f"{path.name}:{n}")
    assert offenders == [], offenders


def test_expected_scripts_exist() -> None:
    names = {p.name for p in SCRIPTS.glob("*.ps1")}
    assert {"common.ps1", "setup.ps1", "research.ps1", "doctor.ps1", "run_live.ps1"} <= names
