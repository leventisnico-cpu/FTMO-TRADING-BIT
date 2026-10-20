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


def test_keep_awake_is_a_no_op_off_windows(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    from ftmo_bot import cli

    monkeypatch.setattr(cli.sys, "platform", "linux")
    assert cli._keep_awake() is False


def test_keep_awake_calls_kernel32_on_windows(monkeypatch) -> None:  # type: ignore[no-untyped-def]
    import ctypes
    from types import SimpleNamespace

    from ftmo_bot import cli

    calls: list[int] = []
    kernel32 = SimpleNamespace(SetThreadExecutionState=lambda flags: calls.append(flags) or 1)
    monkeypatch.setattr(cli.sys, "platform", "win32")
    monkeypatch.setattr(ctypes, "windll", SimpleNamespace(kernel32=kernel32), raising=False)
    assert cli._keep_awake() is True
    assert calls == [0x80000001]  # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
