"""HistData.com fallback: token scrape, EST→UTC decode, month→UTC-day split with
carry-over at month boundaries, resume, and the one-provider-per-folder rule."""

from __future__ import annotations

import io
import zipfile
from collections.abc import Mapping
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

import pandas as pd
import pytest

from ftmo_bot.cli import main
from ftmo_bot.data import histdata as hd
from ftmo_bot.data.dukascopy import day_path

PAGE = (
    '<form id="file_down" method="POST" action="/get.php">'
    '<input type="hidden" name="tk" id="tk" value="abc123TOKEN">'
    '<input type="hidden" name="fxpair" id="fxpair" value="NSXUSD"></form>'
)


def est_rows(start_est: datetime, n: int, step: timedelta, price: float = 1.1) -> str:
    rows = []
    for i in range(n):
        t = start_est + i * step
        stamp = t.strftime("%Y%m%d %H%M%S") + f"{t.microsecond // 1000:03d}"
        rows.append(f"{stamp},{price + i * 1e-5:.6f},{price + 2e-5 + i * 1e-5:.6f},0")
    return "\n".join(rows) + "\n"


def zip_bytes(csv: str, name: str = "DAT_ASCII_EURUSD_T_202001.csv") -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(name, csv)
    return buf.getvalue()


class FakeTransport:
    """Serves the month page and the zip for whichever months it was given."""

    def __init__(self, months: dict[tuple[int, int], str]) -> None:
        self.months = months
        self.calls: list[tuple[str, dict[str, str]]] = []

    def __call__(self, url: str, body: bytes | None, headers: Mapping[str, str]) -> bytes:
        if body is None:
            self.calls.append(("GET", {"url": url}))
            year, month = (int(x) for x in url.rsplit("/", 2)[-2:])
            return PAGE.encode() if (year, month) in self.months else b"<html>no data</html>"
        form = dict(p.split("=") for p in body.decode().split("&"))
        self.calls.append(("POST", form))
        assert form["tk"] == "abc123TOKEN" and form["platform"] == "ASCII"
        year, month = int(form["datemonth"][:4]), int(form["datemonth"][4:])
        return zip_bytes(self.months[(year, month)])


def test_extract_token_and_missing() -> None:
    assert hd.extract_token(PAGE) == "abc123TOKEN"
    with pytest.raises(hd.MonthUnavailable):
        hd.extract_token("<html>Sorry, no data</html>")


def test_decode_shifts_fixed_est_to_utc_and_keeps_ms() -> None:
    csv = "20200101 170003232,1.121920,1.122410,0\n20200706 093000500,1.130000,1.130100,0\n"
    df = hd.decode_month_zip(zip_bytes(csv))
    assert list(df.columns) == ["ts_utc", "bid", "ask"]
    assert str(df["ts_utc"].dtype) == "datetime64[ns, UTC]"
    # EST is UTC-5 all year: no DST shift in July either.
    assert df["ts_utc"].iloc[0] == pd.Timestamp("2020-01-01 22:00:03.232", tz="UTC")
    assert df["ts_utc"].iloc[1] == pd.Timestamp("2020-07-06 14:30:00.500", tz="UTC")
    assert df["bid"].iloc[0] == 1.12192 and df["ask"].iloc[0] == 1.12241


def test_decode_empty_zip_gives_empty_ticks() -> None:
    assert hd.decode_month_zip(zip_bytes("")).empty


def test_month_split_carry_and_resume(tmp_path: Path) -> None:
    # Jan 2020 (EST): ticks on Jan 2 and on Jan 31 23:30 EST (= Feb 1 04:30 UTC).
    jan = est_rows(datetime(2020, 1, 2, 3, 0), 10, timedelta(minutes=1)) + est_rows(
        datetime(2020, 1, 31, 23, 30), 5, timedelta(minutes=1)
    )
    # Feb 2020: ticks on Feb 1 06:00 EST (= 11:00 UTC) and Feb 10.
    feb = est_rows(datetime(2020, 2, 1, 6, 0), 3, timedelta(minutes=1)) + est_rows(
        datetime(2020, 2, 10, 9, 0), 4, timedelta(minutes=1)
    )
    t = FakeTransport({(2020, 1): jan, (2020, 2): feb})

    paths = hd.download_range(
        "EURUSD",
        "EURUSD",
        date(2020, 1, 1),
        date(2020, 2, 29),
        tmp_path,
        t,
        today_utc=date(2020, 3, 15),
    )
    names = [p.name for p in paths]
    assert names[0] == "2020-01-01.parquet" and names[-1] == "2020-02-29.parquet"
    assert len(paths) == 31 + 29  # every UTC day written, weekends included
    # Dec 2019 was asked for (lead-in month) but is not served: only its page is fetched.
    assert ("GET", {"url": hd.page_url("eurusd", 2019, 12)}) in t.calls
    posts = [c for c in t.calls if c[0] == "POST"]
    assert [c[1]["datemonth"] for c in posts] == ["202001", "202002"]

    feb1 = pd.read_parquet(day_path(tmp_path, "EURUSD", date(2020, 2, 1)))
    # 5 ticks carried from the January zip (04:30 UTC) + 3 from February (11:00 UTC).
    assert len(feb1) == 8
    assert feb1["ts_utc"].is_monotonic_increasing
    assert feb1["ts_utc"].iloc[0] == pd.Timestamp("2020-02-01 04:30", tz="UTC")
    assert feb1["ts_utc"].iloc[-1] == pd.Timestamp("2020-02-01 11:02", tz="UTC")
    jan2 = pd.read_parquet(day_path(tmp_path, "EURUSD", date(2020, 1, 2)))
    assert len(jan2) == 10 and jan2["ts_utc"].iloc[0] == pd.Timestamp("2020-01-02 08:00", tz="UTC")
    assert pd.read_parquet(day_path(tmp_path, "EURUSD", date(2020, 1, 5))).empty  # Sunday
    assert hd.carry_path(tmp_path, "EURUSD", date(2020, 3, 1)).exists()
    assert hd.source_marker(tmp_path, "EURUSD").read_text(encoding="utf-8").strip() == "histdata"

    # Re-run: everything on disk, nothing fetched again.
    before = len(t.calls)
    assert (
        hd.download_range(
            "EURUSD",
            "EURUSD",
            date(2020, 1, 1),
            date(2020, 2, 29),
            tmp_path,
            t,
            today_utc=date(2020, 3, 15),
        )
        == []
    )
    assert len(t.calls) == before


def test_unpublished_recent_month_ends_the_run_quietly(tmp_path: Path) -> None:
    t = FakeTransport({(2020, 1): est_rows(datetime(2020, 1, 2, 3, 0), 3, timedelta(minutes=1))})
    paths = hd.download_range(
        "EURUSD",
        "EURUSD",
        date(2020, 1, 1),
        date(2020, 2, 20),
        tmp_path,
        t,
        today_utc=date(2020, 2, 21),
    )
    assert [p.name for p in paths][-1] == "2020-01-31.parquet"


def test_missing_old_month_is_an_error(tmp_path: Path) -> None:
    t = FakeTransport({(2020, 1): est_rows(datetime(2020, 1, 2, 3, 0), 3, timedelta(minutes=1))})
    with pytest.raises(hd.MonthUnavailable):
        hd.download_range(
            "EURUSD",
            "EURUSD",
            date(2020, 1, 1),
            date(2020, 3, 31),
            tmp_path,
            t,
            today_utc=date(2021, 1, 1),
        )


def test_claim_source_refuses_to_mix_providers(tmp_path: Path) -> None:
    hd.claim_source(tmp_path, "EURUSD", "histdata")
    hd.claim_source(tmp_path, "EURUSD", "histdata")  # idempotent
    with pytest.raises(hd.SourceMismatch):
        hd.claim_source(tmp_path, "EURUSD", "dukascopy")
    # A folder written before markers existed holds Dukascopy ticks.
    (tmp_path / "GBPUSD").mkdir()
    (tmp_path / "GBPUSD" / "2020-01-02.parquet").write_bytes(b"")
    with pytest.raises(hd.SourceMismatch):
        hd.claim_source(tmp_path, "GBPUSD", "histdata")
    hd.claim_source(tmp_path, "GBPUSD", "dukascopy")
    assert hd.source_marker(tmp_path, "GBPUSD").read_text(encoding="utf-8").strip() == "dukascopy"


def test_cli_download_source_histdata(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    t = FakeTransport({(2020, 1): est_rows(datetime(2020, 1, 2, 3, 0), 3, timedelta(minutes=1))})
    monkeypatch.setattr(hd, "HttpTransport", lambda: t)
    monkeypatch.setattr(hd, "datetime", _FrozenDatetime)
    rc = main(
        [
            "--raw-dir",
            str(tmp_path),
            "download",
            "--symbol",
            "NAS100",
            "--from",
            "2020-01-01",
            "--to",
            "2020-01-31",
            "--source",
            "histdata",
        ]
    )
    assert rc == 0
    assert [c[1]["fxpair"] for c in t.calls if c[0] == "POST"] == ["NSXUSD"]
    assert day_path(tmp_path, "NAS100", date(2020, 1, 31)).exists()
    # Same folder, other provider: refused with exit code 2.
    rc = main(
        [
            "--raw-dir",
            str(tmp_path),
            "download",
            "--symbol",
            "NAS100",
            "--from",
            "2020-01-01",
            "--to",
            "2020-01-31",
        ]
    )
    assert rc == 2


class _FrozenDatetime(datetime):
    @classmethod
    def now(cls, tz: object = None) -> _FrozenDatetime:  # type: ignore[override]
        return cls(2020, 3, 15, tzinfo=UTC)
