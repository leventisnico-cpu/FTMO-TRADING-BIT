"""HistData.com tick download: the fallback when Dukascopy's datafeed is down.

HistData publishes one zip per instrument-month ("Generic ASCII, tick data
quotes") holding a CSV ``YYYYMMDD HHMMSSmmm,bid,ask,volume`` stamped in fixed
EST (UTC-5, no daylight saving). Getting a zip takes two requests: GET the
month page to read the ``tk`` form token, then POST it to ``get.php``.

Output is identical to :mod:`ftmo_bot.data.dukascopy`: one parquet per symbol
per UTC day at ``{raw_dir}/{symbol}/{YYYY-MM-DD}.parquet`` with columns
``ts_utc`` (datetime64[ns, UTC]), ``bid``, ``ask``, an empty file for days
without ticks, so resample / integrity / backtest do not know the difference.

HistData cuts months at EST midnight (05:00 UTC), so the first UTC day of a
month is complete only once the *previous* month's zip has been decoded: those
00:00-05:00 UTC ticks are parked in ``{YYYY-MM-DD}.carry`` and merged when the
month itself is processed. ``download_range`` therefore starts one month
before ``start``. Every write is atomic and a month already on disk is
skipped, so an interrupted download resumes.

A symbol folder records which provider filled it in ``_source.txt``; the CLI
refuses to mix providers inside one folder (different spreads, different tick
density, different index CFD).
"""

from __future__ import annotations

import http.cookiejar
import io
import logging
import re
import time as _time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from calendar import monthrange
from collections.abc import Callable, Mapping
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any

import pandas as pd

from ftmo_bot.data.dukascopy import DEFAULT_HEADERS, day_path, empty_ticks

log = logging.getLogger(__name__)

SOURCE = "histdata"
PAGE_URL = (
    "https://www.histdata.com/download-free-forex-historical-data/"
    "?/ascii/tick-data-quotes/{pair}/{year}/{month}"
)
POST_URL = "https://www.histdata.com/get.php"
EST_OFFSET = timedelta(hours=5)  # HistData stamps in EST without DST: UTC = EST + 5h
_TOKEN_RE = re.compile(r'<input[^>]*\bid="tk"[^>]*\bvalue="([A-Za-z0-9]+)"')

# (url, body or None for GET, extra headers) -> response bytes
Transport = Callable[[str, bytes | None, Mapping[str, str]], bytes]


class MonthUnavailable(RuntimeError):
    """HistData has no download token for that instrument-month (not published)."""


class SourceMismatch(RuntimeError):
    """The symbol folder already holds ticks from another provider."""


class HttpTransport:
    """Polite urllib transport with a cookie jar and exponential-backoff retries.

    328 requests fetch six years of four instruments, so the pace is gentle:
    ``min_interval_s`` between requests, and a 5xx / network error waits
    ``backoff_s * 2**n`` (capped) before each of ``retries`` attempts.
    """

    def __init__(
        self,
        min_interval_s: float = 2.0,
        retries: int = 8,
        backoff_s: float = 5.0,
        max_delay_s: float = 120.0,
        timeout_s: float = 300.0,
        sleep: Callable[[float], None] = _time.sleep,
        clock: Callable[[], float] = _time.monotonic,
    ) -> None:
        self.min_interval_s = min_interval_s
        self.retries = retries
        self.backoff_s = backoff_s
        self.max_delay_s = max_delay_s
        self.timeout_s = timeout_s
        self._sleep = sleep
        self._clock = clock
        self._last = -float("inf")
        opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )
        self._urlopen = opener.open  # urllib, not a file: keeps the encoding audit honest

    def __call__(self, url: str, body: bytes | None, headers: Mapping[str, str]) -> bytes:
        failures = 0
        while True:
            wait = self.min_interval_s - (self._clock() - self._last)
            if wait > 0:
                self._sleep(wait)
            self._last = self._clock()
            try:
                req = urllib.request.Request(url, data=body, headers={**DEFAULT_HEADERS, **headers})
                with self._urlopen(req, timeout=self.timeout_s) as resp:
                    data: bytes = resp.read()
                    return data
            except urllib.error.HTTPError as exc:
                if 400 <= exc.code < 500 and exc.code != 429:
                    raise
                reason: Any = exc
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as exc:
                reason = exc
            failures += 1
            if failures > self.retries:
                raise RuntimeError(f"giving up on {url} after {failures} attempts: {reason}")
            delay = min(self.backoff_s * 2 ** (failures - 1), self.max_delay_s)
            log.warning(
                "histdata fetch failed (%s), retry %d/%d in %.0fs: %s",
                reason,
                failures,
                self.retries,
                delay,
                url,
            )
            self._sleep(delay)


# ------------------------------------------------------------------ fetch


def page_url(pair: str, year: int, month: int) -> str:
    return PAGE_URL.format(pair=pair.lower(), year=year, month=month)


def extract_token(html: str) -> str:
    m = _TOKEN_RE.search(html)
    if not m:
        raise MonthUnavailable("no download token on the page (month not published?)")
    return m.group(1)


def fetch_month(pair: str, year: int, month: int, transport: Transport) -> bytes:
    """Return the month's zip bytes (GET the page for its token, POST get.php)."""
    referer = page_url(pair, year, month)
    token = extract_token(transport(referer, None, {}).decode("utf-8", "replace"))
    form = {
        "tk": token,
        "date": str(year),
        "datemonth": f"{year:04d}{month:02d}",
        "platform": "ASCII",
        "timeframe": "T",
        "fxpair": pair.upper(),
    }
    body = urllib.parse.urlencode(form).encode("ascii")
    payload = transport(
        POST_URL,
        body,
        {
            "Content-Type": "application/x-www-form-urlencoded",
            "Referer": referer,
            "Origin": "https://www.histdata.com",
        },
    )
    if not payload:
        raise MonthUnavailable(f"{pair} {year}-{month:02d}: empty download (token refused?)")
    return payload


# ------------------------------------------------------------------ decode


def decode_month_zip(payload: bytes) -> pd.DataFrame:
    """Zip bytes -> ``ts_utc, bid, ask`` sorted by time (EST stamps shifted to UTC)."""
    with zipfile.ZipFile(io.BytesIO(payload)) as zf:
        names = [n for n in zf.namelist() if n.lower().endswith(".csv")]
        if len(names) != 1:
            raise ValueError(f"expected one CSV in the zip, found {names}")
        raw = zf.read(names[0])
    return decode_csv(raw)


def decode_csv(raw: bytes) -> pd.DataFrame:
    if not raw.strip():
        return empty_ticks()
    df = pd.read_csv(
        io.BytesIO(raw),
        header=None,
        names=["stamp", "bid", "ask", "volume"],
        usecols=["stamp", "bid", "ask"],
        dtype={"stamp": "string", "bid": "float64", "ask": "float64"},
    )
    est = pd.to_datetime(df["stamp"], format="%Y%m%d %H%M%S%f")
    ts = (est + EST_OFFSET).dt.tz_localize("UTC")
    out = pd.DataFrame({"ts_utc": ts, "bid": df["bid"], "ask": df["ask"]})
    out = out.dropna().sort_values("ts_utc", kind="stable").reset_index(drop=True)
    out["ts_utc"] = out["ts_utc"].astype("datetime64[ns, UTC]")
    return out


# ------------------------------------------------------------------ files


def carry_path(raw_dir: Path, symbol: str, day: date) -> Path:
    return raw_dir / symbol / f"{day.isoformat()}.carry"


def source_marker(raw_dir: Path, symbol: str) -> Path:
    return raw_dir / symbol / "_source.txt"


def claim_source(raw_dir: Path, symbol: str, source: str) -> None:
    """Record the tick provider for a symbol folder; refuse to mix providers.

    Folders written before markers existed hold Dukascopy ticks.
    """
    folder = raw_dir / symbol
    marker = source_marker(raw_dir, symbol)
    if marker.exists():
        current = marker.read_text(encoding="utf-8").strip()
    elif any(folder.glob("*.parquet")):
        current = "dukascopy"
    else:
        current = ""
    if current and current != source:
        raise SourceMismatch(
            f"{folder} already holds {current} ticks; refusing to mix in {source}. "
            f"Delete that folder (data is re-downloadable) to switch provider."
        )
    folder.mkdir(parents=True, exist_ok=True)
    if not marker.exists():
        marker.write_text(source + "\n", encoding="utf-8")


def _write(path: Path, df: pd.DataFrame) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    df.to_parquet(tmp, index=False)
    tmp.replace(path)
    return path


def _month_days(year: int, month: int) -> list[date]:
    return [date(year, month, d) for d in range(1, monthrange(year, month)[1] + 1)]


def _next_month_first(year: int, month: int) -> date:
    return date(year + (month == 12), month % 12 + 1, 1)


def download_month(
    symbol: str,
    pair: str,
    year: int,
    month: int,
    raw_dir: Path,
    transport: Transport,
    first_day: date | None = None,
) -> list[Path]:
    """Write every UTC day of the month (from ``first_day`` on) plus the carry
    for the 1st of the next month. Returns [] when everything is already on disk.
    """
    days = [d for d in _month_days(year, month) if first_day is None or d >= first_day]
    nxt = _next_month_first(year, month)
    need_carry = (first_day is None or nxt >= first_day) and not day_path(
        raw_dir, symbol, nxt
    ).exists()
    if all(day_path(raw_dir, symbol, d).exists() for d in days) and (
        not need_carry or carry_path(raw_dir, symbol, nxt).exists()
    ):
        return []
    ticks = decode_month_zip(fetch_month(pair, year, month, transport))
    by_day: dict[date, pd.DataFrame] = {
        d: g.reset_index(drop=True) for d, g in ticks.groupby(ticks["ts_utc"].dt.date, sort=True)
    }
    written: list[Path] = []
    for d in days:
        df = by_day.get(d, empty_ticks())
        if d.day == 1:
            carry = carry_path(raw_dir, symbol, d)
            if carry.exists():
                df = pd.concat([pd.read_parquet(carry), df], ignore_index=True)
            else:
                log.warning(
                    "%s %s: no carry from the previous month; 00:00-05:00 UTC missing", symbol, d
                )
        written.append(_write(day_path(raw_dir, symbol, d), df))
    if need_carry:
        _write(carry_path(raw_dir, symbol, nxt), by_day.get(nxt, empty_ticks()))
    log.info(
        "downloaded %s %04d-%02d from HistData: %d day files, %d ticks",
        symbol,
        year,
        month,
        len(written),
        len(ticks),
    )
    return written


def download_range(
    symbol: str,
    pair: str,
    start: date,
    end: date,
    raw_dir: Path,
    transport: Transport | None = None,
    today_utc: date | None = None,
) -> list[Path]:
    """Download ``[start, end]`` month by month, beginning one month early so
    the first day's 00:00-05:00 UTC ticks are present. Months HistData has not
    published yet (the current one, sometimes the previous) end the run quietly.
    """
    transport = transport or HttpTransport()
    today_utc = today_utc or datetime.now(UTC).date()
    end = min(end, today_utc - timedelta(days=1))
    claim_source(raw_dir, symbol, SOURCE)
    paths: list[Path] = []
    year, month = (start.year - (start.month == 1), (start.month - 2) % 12 + 1)
    while date(year, month, 1) <= end:
        try:
            paths.extend(download_month(symbol, pair, year, month, raw_dir, transport, start))
        except MonthUnavailable as exc:
            if date(year, month, 1) < date(start.year, start.month, 1):
                log.warning(
                    "%s %04d-%02d (lead-in month) unavailable on HistData; %s will miss "
                    "its first 00:00-05:00 UTC: %s",
                    symbol,
                    year,
                    month,
                    start,
                    exc,
                )
            elif _next_month_first(year, month) > today_utc - timedelta(days=45):
                log.warning(
                    "%s %04d-%02d not published yet on HistData, stopping: %s",
                    symbol,
                    year,
                    month,
                    exc,
                )
                break
            else:
                raise
        year, month = (year + (month == 12), month % 12 + 1)
    return paths
