"""Retail sales loader: Iowa liquor sales (data.iowa.gov, public domain) -> SQL Server.

The state publishes one dataset per year ("Iowa Liquor Sales, 2026" and so on), and its API hands
out a whole year at once, as a zip of CSV files. So the loader downloads each year it needs once,
reads it in one pass, and sends each wanted month's lines to staging in chunks
(etl.usp_stage_iowa). Then it loads each month into the star schema in one transaction
(etl.usp_load_iowa_month, which checks the row count first). Monthly runs reload the latest two
months, because the state sometimes corrects recent data.

The yearly files number invoices but not their lines, so each line gets "<invoice>-<n>" in file
order. A month is always reloaded whole, so the numbers only need to be consistent within a load.
"""

from __future__ import annotations

import csv
import datetime as dt
import http.client
import io
import os
import re
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
import zlib
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator

import hbcommon
import hbsql
from hbsql import Login, SqlServer

DATABASE = "RetailSales"
API = "https://idh-be.iowa.gov/api/v1/datasets"
# "Iowa Liquor Sales, <year>" on data.iowa.gov: 2012 is dataset 1249, 2026 is 1263.
YEAR_DATASETS = {year: 1249 + year - 2012 for year in range(2012, 2027)}
# data.gov lists each year's dataset by name, so a new year's number is found there.
CATALOG_PAGE = "https://catalog.data.gov/dataset/iowa-liquor-sales-{year}"
POPULATION_URL = f"{API}/707/rows.csv"     # "County Population in Iowa by Year"
CHUNK_ROWS = 10000
YEARS_BACK = 3                 # same rule as the report_from setting: January 1, three years ago
USER_AGENT = "homebase-portfolio/1.0 (personal data-analysis portfolio)"
DOWNLOAD_DIR = Path(os.environ.get("HB_DOWNLOAD_DIR", "/var/tmp"))

# our column -> the data's column names (first one found wins). The yearly files' names come
# second; the first names are the ones the state used until 2026.
FIELDS: list[tuple[str, tuple[str, ...]]] = [
    ("invoice_line_no", ("invoice_line_no", "invoice_and_item_number", "invoice_item_number")),
    ("invoice_id", ("invoice_id",)),
    ("sale_date", ("date", "sale_date", "ordered_on")),
    ("store_number", ("store", "store_number", "store_no")),
    ("store_name", ("name", "store_name")),
    ("address", ("address", "store_address")),
    ("city", ("city", "store_city")),
    ("zip_code", ("zipcode", "zip_code", "store_zip_code")),
    ("latitude", ("store_location",)),
    ("longitude", ("store_location",)),
    ("county", ("county", "county_name")),
    ("category_number", ("category", "category_number", "category_code")),
    ("category_name", ("category_name",)),
    ("vendor_number", ("vendor_no", "vendor_number")),
    ("vendor_name", ("vendor_name",)),
    ("item_number", ("itemno", "item_number", "item_no")),
    ("item_description", ("im_desc", "item_description")),
    ("pack", ("pack",)),
    ("bottle_volume_ml", ("bottle_volume_ml",)),
    ("state_bottle_cost", ("state_bottle_cost",)),
    ("state_bottle_retail", ("state_bottle_retail",)),
    ("bottles_sold", ("sale_bottles", "bottles_sold", "sales_bottles")),
    ("sale_dollars", ("sale_dollars", "sales_dollars")),
    ("volume_liters", ("sale_liters", "volume_sold_liters", "sales_liters")),
]
REQUIRED = ("sale_date", "sale_dollars")
POINT_RE = re.compile(r"POINT\s*\(\s*(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s*\)", re.IGNORECASE)


# ---------------------------------------------------------------------------
# Parsing (unit tested)
# ---------------------------------------------------------------------------

def column_map(header: list[str]) -> dict[str, int]:
    pos = {h.strip().lower(): i for i, h in enumerate(header)}
    out = {}
    for name, candidates in FIELDS:
        for c in candidates:
            if c in pos:
                out[name] = pos[c]
                break
    missing = [r for r in REQUIRED if r not in out]
    if "invoice_line_no" not in out and "invoice_id" not in out:
        missing.insert(0, "invoice_line_no")
    if missing:
        raise ValueError(f"the sales data has no column for {', '.join(missing)} (columns: {', '.join(header)})")
    return out


def _clean(v: str | None, limit: int = 200) -> str | None:
    if v is None:
        return None
    s = " ".join(v.split())
    return s[:limit] or None


def _int(v: str | None) -> int | None:
    s = (v or "").strip()
    if not s:
        return None
    try:
        return int(float(s))
    except ValueError:
        return None


def _num(v: str | None, places: int = 2) -> float | None:
    s = (v or "").strip().replace(",", "").replace("$", "")
    if not s:
        return None
    try:
        return round(float(s), places)
    except ValueError:
        return None


def _date(v: str | None) -> str | None:
    s = (v or "").strip()
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})", s)
    if m:
        return f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
    m = re.match(r"(\d{1,2})/(\d{1,2})/(\d{4})", s)
    if m:
        return f"{m.group(3)}-{int(m.group(1)):02d}-{int(m.group(2)):02d}"
    return None


def _zip(v: str | None) -> str | None:
    m = re.match(r"\s*(\d{5})", v or "")
    return m.group(1) if m else None


def _place(v: str | None) -> str | None:
    s = _clean(v, 100)
    return s.title() if s else None


def parse_point(v: str | None) -> tuple[float | None, float | None]:
    m = POINT_RE.search(v or "")
    if not m:
        return None, None
    lon, lat = float(m.group(1)), float(m.group(2))
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None, None
    return round(lat, 6), round(lon, 6)


def parse_row(raw: list[str], cols: dict[str, int], month: dt.date,
              line_id: str | None = None) -> list[Any] | None:
    """One CSV row -> the 23-value list etl.usp_stage_iowa expects, or None if unusable.

    line_id is the line's number from LineNumbers, for files that have only invoice numbers.
    """
    def get(name: str) -> str | None:
        i = cols.get(name)
        return raw[i] if i is not None and i < len(raw) else None

    invoice = line_id or _clean(get("invoice_line_no"), 40)
    day = _date(get("sale_date"))
    if not invoice or not day or not day.startswith(month.strftime("%Y-%m")):
        return None
    lat, lon = parse_point(get("latitude"))
    return [
        invoice, day, _int(get("store_number")), _clean(get("store_name")), _clean(get("address")),
        _place(get("city")), _zip(get("zip_code")), lat, lon, _place(get("county")),
        _int(get("category_number")), _clean(get("category_name"), 100), _int(get("vendor_number")),
        _clean(get("vendor_name")), _clean(get("item_number"), 20), _clean(get("item_description")),
        _int(get("pack")), _int(get("bottle_volume_ml")), _num(get("state_bottle_cost")),
        _num(get("state_bottle_retail")), _int(get("bottles_sold")), _num(get("sale_dollars")),
        _num(get("volume_liters")),
    ]


def row_month(raw: list[str], cols: dict[str, int]) -> dt.date | None:
    """The month a CSV row belongs to, from its sale date."""
    i = cols["sale_date"]
    day = _date(raw[i]) if i < len(raw) else None
    return dt.date(int(day[:4]), int(day[5:7]), 1) if day else None


class LineNumbers:
    """Numbers the lines of each invoice 001, 002, ... in file order."""

    def __init__(self) -> None:
        self.seen: dict[str, int] = {}

    def next(self, invoice: str) -> str:
        n = self.seen[invoice] = self.seen.get(invoice, 0) + 1
        return f"{invoice}-{n:03d}"


def month_start(value: str | dt.date) -> dt.date:
    if isinstance(value, dt.date):
        return value.replace(day=1)
    m = re.match(r"^(\d{4})-(\d{1,2})", value.strip())
    if not m:
        raise ValueError(f"not a month: {value!r} (use YYYY-MM)")
    return dt.date(int(m.group(1)), int(m.group(2)), 1)


def add_months(d: dt.date, n: int) -> dt.date:
    y, m = divmod(d.month - 1 + n, 12)
    return dt.date(d.year + y, m + 1, 1)


def months_between(first: dt.date, last: dt.date) -> list[dt.date]:
    out, d = [], month_start(first)
    while d <= last:
        out.append(d)
        d = add_months(d, 1)
    return out


def months_to_load(loaded: Iterable[str], first: dt.date, last: dt.date, refresh: int = 2) -> list[dt.date]:
    """Missing months from `first` to `last`, plus the newest `refresh` loaded months again."""
    done = sorted({month_start(m) for m in loaded})
    want = [m for m in months_between(first, last) if m not in done]
    want += [m for m in done[-refresh:] if first <= m <= last]
    return sorted(set(want))


# ---------------------------------------------------------------------------
# Downloading
# ---------------------------------------------------------------------------

RETRY_CODES = (429, 500, 502, 503, 504)


def http_get(url: str, token: str | None = None, attempts: int = 5, timeout: int = 300,
             opener: Callable[..., Any] = urllib.request.urlopen, pause: float = 15) -> bytes:
    headers = {"User-Agent": USER_AGENT, "Accept": "text/csv, application/json"}
    if token:
        headers["X-App-Token"] = token
    last: Exception | None = None
    for i in range(attempts):
        try:
            with opener(urllib.request.Request(url, headers=headers), timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as exc:
            last = exc
            if exc.code not in RETRY_CODES:
                detail = exc.read().decode("utf-8", "replace")[:300]
                raise RuntimeError(f"data.iowa.gov answered {exc.code}: {detail}") from exc
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            last = exc
        time.sleep(pause * (i + 1))
    raise RuntimeError(f"data.iowa.gov could not be reached: {last}")


def http_download(url: str, dest: Path, attempts: int = 5, timeout: int = 600,
                  opener: Callable[..., Any] = urllib.request.urlopen, pause: float = 15) -> Path:
    """Saves a (large) download to dest, starting over if the connection drops."""
    last: Exception | None = None
    for i in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with opener(req, timeout=timeout) as r, open(dest, "wb") as f:
                while chunk := r.read(1 << 20):
                    f.write(chunk)
            return dest
        except urllib.error.HTTPError as exc:
            last = exc
            if exc.code not in RETRY_CODES:
                raise RuntimeError(f"data.iowa.gov answered {exc.code} for {url}") from exc
        except (urllib.error.URLError, TimeoutError, ConnectionError, http.client.HTTPException) as exc:
            last = exc
        time.sleep(pause * (i + 1))
    raise RuntimeError(f"data.iowa.gov could not be reached: {last}")


def year_dataset(year: int, get: Callable[..., bytes] = http_get) -> int | None:
    """The data.iowa.gov dataset number of one year's sales, or None before it's published."""
    if year in YEAR_DATASETS:
        return YEAR_DATASETS[year]
    try:
        page = get(CATALOG_PAGE.format(year=year)).decode("utf-8", "replace")
    except RuntimeError:
        return None
    m = re.search(r"idh-be\.iowa\.gov/api/v1/datasets/(\d+)/rows\.csv", page)
    return int(m.group(1)) if m else None


def download_year(year: int, get: Callable[..., bytes] = http_get,
                  fetch: Callable[[str, Path], Path] = http_download) -> Path | None:
    """Downloads one year's zip to a temporary file (the caller deletes it), or None if the
    year isn't published yet."""
    dataset = year_dataset(year, get)
    if dataset is None:
        return None
    fd, name = tempfile.mkstemp(prefix=f"iowa-liquor-{year}-", suffix=".zip", dir=DOWNLOAD_DIR)
    os.close(fd)
    try:
        return fetch(f"{API}/{dataset}/rows.csv", Path(name))
    except BaseException:
        Path(name).unlink(missing_ok=True)
        raise


def year_parts(path: Path, year: int) -> Iterator[tuple[list[str], Iterator[list[str]]]]:
    """(header, rows) for each CSV in a year's zip. The names say which year a file holds, so a
    wrong dataset number fails here instead of loading the wrong year."""
    with zipfile.ZipFile(path) as z:
        parts = sorted((i for i in z.infolist() if i.filename.lower().endswith(".csv")),
                       key=lambda i: i.filename)
        if not parts:
            raise ValueError("the download has no CSV files in it")
        for info in parts:
            if not re.search(rf"(^|\D){year}(\D|$)", info.filename):
                raise ValueError(f"{info.filename} isn't the {year} sales file")
            with z.open(info) as raw:
                reader = csv.reader(io.TextIOWrapper(raw, encoding="utf-8-sig", newline=""))
                header = next(reader, None)
                if header:
                    yield header, reader


def zip_head_text(head: bytes) -> str:
    """The start of the first file in a zip, from only the zip's first bytes."""
    if head[:4] != b"PK\x03\x04":
        raise ValueError("not a zip download")
    method = int.from_bytes(head[8:10], "little")
    start = 30 + int.from_bytes(head[26:28], "little") + int.from_bytes(head[28:30], "little")
    data = head[start:]
    if method == 8:
        data = zlib.decompressobj(-15).decompress(data)
    elif method != 0:
        raise ValueError(f"unexpected zip compression {method}")
    return data.split(b"PK\x07\x08")[0].split(b"PK\x03\x04")[0].decode("utf-8-sig", "replace")


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def etl_login() -> Login:
    return Login("etl", hbsql.check_password(hbcommon.read_secret("mssql-etl-password") or ""), DATABASE)


def load_year(srv: SqlServer, who: Login, year: int, months: Iterable[dt.date],
              download: Callable[[int], Path | None]) -> list[dict[str, Any]]:
    """Loads the given months of one year from that year's download, one result per month."""
    wanted = sorted(set(months))
    path = download(year)
    if path is None:
        return [{"load_month": m.isoformat(), "source_rows": 0, "skipped_rows": 0, "empty": True}
                for m in wanted]
    buffers: dict[dt.date, list[list[Any]]] = {m: [] for m in wanted}
    sent = dict.fromkeys(wanted, 0)
    skipped = dict.fromkeys(wanted, 0)

    def flush(month: dt.date) -> None:
        if buffers[month]:
            srv.call(who, "etl.usp_stage_iowa", load_month=month, rows=buffers[month],
                     first_chunk=sent[month] == 0)
            sent[month] += len(buffers[month])
            buffers[month] = []

    try:
        numbers = LineNumbers()
        for header, rows in year_parts(path, year):
            cols = column_map(header)
            numbered = "invoice_line_no" not in cols
            for raw in rows:
                month = row_month(raw, cols) if raw else None
                if month not in buffers:
                    continue
                line_id = None
                if numbered:
                    i = cols["invoice_id"]
                    invoice = _clean(raw[i], 30) if i < len(raw) else None
                    line_id = numbers.next(invoice) if invoice else None
                row = parse_row(raw, cols, month, line_id)
                if row is None:
                    skipped[month] += 1
                    continue
                buffers[month].append(row)
                if len(buffers[month]) >= CHUNK_ROWS:
                    flush(month)
        for month in wanted:
            flush(month)
    finally:
        path.unlink(missing_ok=True)
    results = []
    for month in wanted:
        if sent[month] == 0:
            results.append({"load_month": month.isoformat(), "source_rows": 0,
                            "skipped_rows": skipped[month], "empty": True})
            continue
        res = srv.call(who, "etl.usp_load_iowa_month", load_month=month, expected_rows=sent[month]) or {}
        res["skipped_rows"] = skipped[month]
        results.append(res)
    return results


def run(env: dict[str, str] | None = None, srv: SqlServer | None = None, first: str | None = None,
        last: str | None = None, today: dt.date | None = None, get: Callable[..., bytes] = http_get,
        download: Callable[[int], Path | None] | None = None) -> dict[str, Any]:
    env = env if env is not None else hbcommon.load_env()
    if env.get("HB_SQL") != "1":
        return {"ok": True, "skipped": "SQL Server is not set up"}
    srv = srv or SqlServer(env)
    who = etl_login()
    download = download or (lambda year: download_year(year, get))
    today = today or dt.date.today()
    first_m = month_start(first or env.get("HB_RETAIL_FROM") or dt.date(today.year - YEARS_BACK, 1, 1))
    last_m = month_start(last) if last else add_months(today.replace(day=1), -1)
    loaded = [m["load_month"] for m in (srv.call(who, "etl.usp_get_loaded_months") or [])]
    todo = months_to_load(loaded, first_m, last_m)
    done: list[dict[str, Any]] = []
    started = int(time.time())
    for year in sorted({m.year for m in todo}):
        months = [m for m in todo if m.year == year]
        hbcommon.write_status("portfolio-retail", {
            "ok": True, "running": True, "started": started, "current_year": year,
            "current_month": months[0].isoformat(), "months_done": len(done), "months_total": len(todo),
            "last_success": (hbcommon.read_status("portfolio-retail") or {}).get("last_success")})
        done.extend(load_year(srv, who, year, months, download))
    st = {"ok": True, "running": False, "finished": int(time.time()), "months": done,
          "months_loaded": len([d for d in done if not d.get("empty")]), "rows_loaded": sum(int(d.get("rows_loaded") or 0) for d in done)}
    st["last_success"] = st["finished"]
    hbcommon.write_status("portfolio-retail", st)
    return st


def population(env: dict[str, str] | None = None, srv: SqlServer | None = None,
               get: Callable[..., bytes] = http_get) -> dict[str, Any]:
    """County population by year (another data.iowa.gov dataset) for sales per person."""
    env = env if env is not None else hbcommon.load_env()
    srv = srv or SqlServer(env)
    text = get(POPULATION_URL).decode("utf-8-sig", "replace")
    rows = []
    for r in csv.DictReader(io.StringIO(text)):
        name = re.sub(r"\s+County$", "", (r.get("geographic_name") or "").strip(), flags=re.IGNORECASE)
        year = (r.get("calendar_year") or "")[:4]
        pop = _int(r.get("population"))
        if name and year.isdigit() and int(year) >= 2015 and pop:
            rows.append({"county": name.title(), "year": int(year), "population": pop})
    if not rows:
        return {"ok": False, "message": "no population rows came back"}
    res = srv.call(etl_login(), "etl.usp_load_population", payload=rows)
    return {"ok": True, **(res or {})}


def probe(get: Callable[..., bytes] = http_get, opener: Callable[..., Any] = urllib.request.urlopen,
          today: dt.date | None = None) -> dict[str, Any]:
    """The first rows of this year's file (only its first bytes are downloaded): shows the
    column names and how they parse."""
    year = (today or dt.date.today()).year
    dataset = year_dataset(year, get)
    if dataset is None:
        return {"ok": False, "error": f"Iowa hasn't published a {year} sales dataset yet"}
    req = urllib.request.Request(f"{API}/{dataset}/rows.csv", headers={"User-Agent": USER_AGENT})
    with opener(req, timeout=120) as r:
        head = r.read(256 * 1024)
    lines = zip_head_text(head).splitlines()[:-1]   # the last line is usually cut off
    reader = csv.reader(lines)
    header = next(reader, [])
    rows = [r for r in reader if r][:3]
    out: dict[str, Any] = {"ok": True, "year": year, "dataset": dataset, "columns": header}
    try:
        cols = column_map(header)
        out["mapped"] = {name: header[i] for name, i in cols.items()}
        out["unmapped"] = [n for n, _c in FIELDS if n not in cols]
        if rows:
            month = row_month(rows[0], cols)
            line_id = None
            if "invoice_line_no" not in cols:
                line_id = LineNumbers().next(_clean(rows[0][cols["invoice_id"]], 30) or "?")
            out["sample"] = parse_row(rows[0], cols, month, line_id) if month else None
    except ValueError as exc:
        out["ok"] = False
        out["error"] = str(exc)
    return out
