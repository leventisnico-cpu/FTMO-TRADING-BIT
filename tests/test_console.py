"""CLI output survives a console that cannot encode "→" (Windows cp1252 when redirected)."""

from __future__ import annotations

import io
import sys

import pytest

from ftmo_bot.cli import _safe_console


def test_cp1252_console_does_not_crash(monkeypatch: pytest.MonkeyPatch) -> None:
    raw = io.BytesIO()
    cp1252 = io.TextIOWrapper(raw, encoding="cp1252", errors="strict")
    monkeypatch.setattr(sys, "stdout", cp1252)
    with pytest.raises(UnicodeEncodeError):
        print("ticks → bars")
    _safe_console()
    print("ticks → bars ± 3σ")
    cp1252.flush()
    assert raw.getvalue().decode("cp1252").strip() == "ticks \\u2192 bars ± 3\\u03c3"
