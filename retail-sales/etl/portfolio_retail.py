"""Retail sales loader: Iowa liquor sales (data.iowa.gov, public domain) -> SQL Server.

One month at a time: download the month's sales lines from the state's open-data API in pages,
send them to staging in chunks (etl.usp_stage_iowa), then load the month into the star schema
in one transaction (etl.usp_load_iowa_month, which checks the row count first). Monthly runs
reload the latest two months, because the state sometimes corrects recent data.
"""

from __future__ import annotations

import csv
import datetime as dt
import io
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Iterable

import hbcommon
import hbsql
from hbsql import Login, SqlServer

DATABASE = "RetailSales"
SALES_URL = "https://data.iowa.gov/resource/m3tr-qhgy.csv"
POPULATION_URL = "https://data.iowa.gov/resource/qtnr-zsrc.json"
PAGE_ROWS = 50000
CHUNK_ROWS = 10000
YEARS_BACK = 3                 # same rule as the report_from setting: January 1, three years ago
USER_AGENT = "homebase-portfolio/1.0 (personal data-analysis portfolio)"

# our column -> the API's column names (first one found wins)
FIELDS: list[tuple[str, tuple[str, ...]]] = [
    ("invoice_line_no", ("invoice_line_no", "invoice_and_item_number", "invoice_item_number")),
    ("sale_date", ("date", "sale_date")),
    ("store_number", ("store", "store_number")),
    ("store_name", ("name", "store_name")),
    ("address", ("address",)),
    ("city", ("city",)),
    ("zip_code", ("zipcode", "zip_code")),
    ("latitude", ("store_location",)),
    ("longitude", ("store_location",)),
    ("county", ("county",)),
    ("category_number", ("category", "category_number")),
    ("category_name", ("category_name",)),
    ("vendor_number", ("vendor_no", "vendor_number")),
    ("vendor_name", ("vendor_name",)),
    ("item_number", ("itemno", "item_number")),
    ("item_description", ("im_desc", "item_description")),
    ("pack", ("pack",)),
    ("bottle_volume_ml", ("bottle_volume_ml",)),
    ("state_bottle_cost", ("state_bottle_cost",)),
    ("state_bottle_retail", ("state_bottle_retail",)),
    ("bottles_sold", ("sale_bottles", "bottles_sold")),
    ("sale_dollars", ("sale_dollars",)),
    ("volume_liters", ("sale_liters", "volume_sold_liters")),
]
REQUIRED = ("invoice_line_no", "sale_date", "sale_dollars")
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


def parse_row(raw: list[str], cols: dict[str, int], month: dt.date) -> list[Any] | None:
    """One CSV row -> the 23-value list etl.usp_stage_iowa expects, or None if unusable."""
    def get(name: str) -> str | None:
        i = cols.get(name)
        return raw[i] if i is not None and i < len(raw) else None

    invoice = _clean(get("invoice_line_no"), 40)
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


def sales_url(month: dt.date, offset: int, limit: int = PAGE_ROWS) -> str:
    nxt = add_months(month, 1)
    q = {
        "$where": f"date >= '{month.isoformat()}T00:00:00.000' AND date < '{nxt.isoformat()}T00:00:00.000'",
        "$order": ":id",
        "$limit": str(limit),
        "$offset": str(offset),
    }
    return SALES_URL + "?" + urllib.parse.urlencode(q)


# ---------------------------------------------------------------------------
# Downloading
# ---------------------------------------------------------------------------

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
            if exc.code not in (429, 500, 502, 503, 504):
                detail = exc.read().decode("utf-8", "replace")[:300]
                raise RuntimeError(f"data.iowa.gov answered {exc.code}: {detail}") from exc
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            last = exc
        time.sleep(pause * (i + 1))
    raise RuntimeError(f"data.iowa.gov could not be reached: {last}")


def fetch_month(month: dt.date, token: str | None = None, get: Callable[..., bytes] = http_get) -> Iterable[tuple[list[str], list[list[str]]]]:
    """Yields (header, rows) pages for one month."""
    offset = 0
    while True:
        text = get(sales_url(month, offset), token).decode("utf-8-sig", "replace")
        reader = csv.reader(io.StringIO(text))
        header = next(reader, None)
        if not header:
            return
        rows = [r for r in reader if r]
        if not rows:
            return
        yield header, rows
        if len(rows) < PAGE_ROWS:
            return
        offset += PAGE_ROWS


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

def etl_login() -> Login:
    return Login("etl", hbsql.check_password(hbcommon.read_secret("mssql-etl-password") or ""), DATABASE)


def load_month(srv: SqlServer, who: Login, month: dt.date, token: str | None,
               get: Callable[..., bytes] = http_get) -> dict[str, Any]:
    sent = skipped = 0
    first = True
    cols: dict[str, int] | None = None
    for header, raw_rows in fetch_month(month, token, get):
        cols = cols or column_map(header)
        parsed = []
        for raw in raw_rows:
            row = parse_row(raw, cols, month)
            if row is None:
                skipped += 1
            else:
                parsed.append(row)
        for i in range(0, len(parsed), CHUNK_ROWS):
            srv.call(who, "etl.usp_stage_iowa", load_month=month, rows=parsed[i:i + CHUNK_ROWS], first_chunk=first)
            first = False
            sent += len(parsed[i:i + CHUNK_ROWS])
    if sent == 0:
        return {"load_month": month.isoformat(), "source_rows": 0, "skipped_rows": skipped, "empty": True}
    res = srv.call(who, "etl.usp_load_iowa_month", load_month=month, expected_rows=sent) or {}
    res["skipped_rows"] = skipped
    return res


def run(env: dict[str, str] | None = None, srv: SqlServer | None = None, first: str | None = None,
        last: str | None = None, today: dt.date | None = None, get: Callable[..., bytes] = http_get) -> dict[str, Any]:
    env = env if env is not None else hbcommon.load_env()
    if env.get("HB_SQL") != "1":
        return {"ok": True, "skipped": "SQL Server is not set up"}
    srv = srv or SqlServer(env)
    who = etl_login()
    token = hbcommon.read_secret("socrata-app-token")
    today = today or dt.date.today()
    first_m = month_start(first or env.get("HB_RETAIL_FROM") or dt.date(today.year - YEARS_BACK, 1, 1))
    last_m = month_start(last) if last else add_months(today.replace(day=1), -1)
    loaded = [m["load_month"] for m in (srv.call(who, "etl.usp_get_loaded_months") or [])]
    todo = months_to_load(loaded, first_m, last_m)
    done: list[dict[str, Any]] = []
    started = int(time.time())
    for i, month in enumerate(todo):
        hbcommon.write_status("portfolio-retail", {
            "ok": True, "running": True, "started": started, "current_month": month.isoformat(),
            "months_done": i, "months_total": len(todo), "last_success": (hbcommon.read_status("portfolio-retail") or {}).get("last_success")})
        res = load_month(srv, who, month, token, get)
        done.append(res)
        if res.get("empty") and month >= add_months(last_m, -1):
            break   # the newest months aren't published yet
    st = {"ok": True, "running": False, "finished": int(time.time()), "months": done,
          "months_loaded": len([d for d in done if not d.get("empty")]), "rows_loaded": sum(int(d.get("rows_loaded") or 0) for d in done)}
    st["last_success"] = st["finished"]
    hbcommon.write_status("portfolio-retail", st)
    return st


def population(env: dict[str, str] | None = None, srv: SqlServer | None = None,
               get: Callable[..., bytes] = http_get) -> dict[str, Any]:
    """County population by year (another data.iowa.gov dataset) for sales per person."""
    import json
    env = env if env is not None else hbcommon.load_env()
    srv = srv or SqlServer(env)
    q = urllib.parse.urlencode({"$select": "geographicname,year,population",
                                "$where": "year >= '2015-01-01T00:00:00'", "$limit": "50000"})
    data = json.loads(get(POPULATION_URL + "?" + q, hbcommon.read_secret("socrata-app-token")).decode("utf-8"))
    rows = []
    for r in data:
        name = re.sub(r"\s+County$", "", (r.get("geographicname") or "").strip(), flags=re.IGNORECASE)
        year = (r.get("year") or "")[:4]
        pop = _int(r.get("population"))
        if name and year.isdigit() and pop:
            rows.append({"county": name.title(), "year": int(year), "population": pop})
    if not rows:
        return {"ok": False, "message": "no population rows came back"}
    res = srv.call(etl_login(), "etl.usp_load_population", payload=rows)
    return {"ok": True, **(res or {})}


def probe(get: Callable[..., bytes] = http_get) -> dict[str, Any]:
    """A few recent rows: shows the API's column names and how they parse."""
    q = urllib.parse.urlencode({"$order": "date DESC", "$limit": "3"})
    text = get(SALES_URL + "?" + q, hbcommon.read_secret("socrata-app-token")).decode("utf-8-sig", "replace")
    reader = csv.reader(io.StringIO(text))
    header = next(reader, [])
    rows = [r for r in reader if r]
    out: dict[str, Any] = {"ok": True, "columns": header}
    try:
        cols = column_map(header)
        out["mapped"] = {name: header[i] for name, i in cols.items()}
        out["unmapped"] = [n for n, _c in FIELDS if n not in cols]
        if rows:
            d = _date(rows[0][cols["sale_date"]])
            out["sample"] = parse_row(rows[0], cols, month_start(d)) if d else None
    except ValueError as exc:
        out["ok"] = False
        out["error"] = str(exc)
    return out
