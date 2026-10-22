"""Home climate loader: Home Assistant history -> SQL Server (HomeClimate database).

Every 15 minutes:
  1. tell the warehouse which Home Assistant entities hold which measurement (etl.usp_set_entities)
  2. ask Home Assistant for every state change since the last one stored (REST history API)
  3. send them in chunks (etl.usp_ingest_ha_states; duplicates are ignored)
  4. rebuild the 5-minute facts, runs and events for that window (etl.usp_refresh_climate)
"""

from __future__ import annotations

import datetime as dt
import json
import time
import urllib.parse
from pathlib import Path
from typing import Any, Callable, Iterable

import hbcommon
import hbsql
from hbsql import Login, SqlServer

DATABASE = "HomeClimate"
FIRST_RUN_DAYS = 10            # Home Assistant keeps 10 days of history by default
OVERLAP = dt.timedelta(minutes=15)
CHUNK_ROWS = 3000
HELPERS = {
    "decision_mode": "input_select.dehumidifier_last_mode",
    "auto_switch": "input_boolean.dehumidifier_auto",
    "too_hot": "binary_sensor.apartment_hot",
}
TEMPLATE_SENSORS = {
    # entity id the climate package normally gets -> its friendly name (to find a renamed id)
    "sensor.outdoor_absolute_humidity": "Outdoor absolute humidity",
    "sensor.dehumidifier_target": "Dehumidifier target",
}
KEEP_ATTRIBUTES = {
    # only the attributes the warehouse reads are stored
    "default": ("unit_of_measurement",),
    "weather": ("temperature", "temperature_unit", "humidity"),
    "humidifier": ("mode", "humidity", "current_humidity", "action"),
}


# ---------------------------------------------------------------------------
# Pure helpers (unit tested)
# ---------------------------------------------------------------------------

def find_entity(states: dict[str, dict[str, Any]], default_id: str, friendly_name: str) -> str:
    if default_id in states:
        return default_id
    domain = default_id.split(".", 1)[0]
    for eid, s in states.items():
        if eid.startswith(domain + ".") and (s.get("attributes") or {}).get("friendly_name") == friendly_name:
            return eid
    return ""


def entity_plan(climate: dict[str, Any], states: dict[str, dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    """Which entities feed which metric/role, given the climate settings ha-setup saved and the
    entities Home Assistant has right now."""
    metrics: list[dict[str, Any]] = []
    roles: list[dict[str, Any]] = []

    def metric(eid: str | None, code: str, source: str, attribute: str | None = None, unit: str | None = None) -> None:
        if eid and eid in states:
            metrics.append({"entity_id": eid, "metric_code": code, "value_source": source,
                            "attribute_path": attribute, "unit_path": unit})

    def role(code: str, eid: str | None) -> None:
        if eid and eid in states:
            roles.append({"role_code": code, "entity_id": eid})

    weather = climate.get("weather") or ("weather.forecast_home" if "weather.forecast_home" in states else "")
    if not weather:
        weather = next((e for e in sorted(states) if e.startswith("weather.")), "")
    metric(climate.get("humidity"), "indoor_humidity", "state")
    metric(climate.get("temperature"), "indoor_temp_f", "state", unit="$.unit_of_measurement")
    metric(weather, "outdoor_temp_f", "attribute", "$.temperature", "$.temperature_unit")
    metric(weather, "outdoor_humidity", "attribute", "$.humidity")
    ah = find_entity(states, "sensor.outdoor_absolute_humidity", TEMPLATE_SENSORS["sensor.outdoor_absolute_humidity"])
    metric(ah, "outdoor_abs_humidity", "state")
    metric(climate.get("dehumidifier"), "dehumidifier_humidity", "attribute", "$.current_humidity")
    target = find_entity(states, "sensor.dehumidifier_target", TEMPLATE_SENSORS["sensor.dehumidifier_target"])
    metric(target, "target_low", "band_low")
    metric(target, "target_high", "band_high")
    role("dehumidifier", climate.get("dehumidifier"))
    role("tank_full", climate.get("tank_full"))
    for code, eid in HELPERS.items():
        role(code, eid)
    return {"metrics": metrics, "roles": roles}


def plan_entities(plan: dict[str, list[dict[str, Any]]]) -> list[str]:
    seen: list[str] = []
    for item in plan["metrics"] + plan["roles"]:
        if item["entity_id"] not in seen:
            seen.append(item["entity_id"])
    return seen


def parse_ha_time(value: str) -> dt.datetime:
    """Home Assistant ISO time (with offset) -> naive UTC datetime."""
    t = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if t.tzinfo is None:
        return t
    return t.astimezone(dt.timezone.utc).replace(tzinfo=None)


def iso_ms(t: dt.datetime) -> str:
    return t.isoformat(timespec="milliseconds")


def slim_attributes(entity_id: str, attributes: dict[str, Any] | None) -> dict[str, Any]:
    domain = entity_id.split(".", 1)[0]
    keep = KEEP_ATTRIBUTES.get(domain, KEEP_ATTRIBUTES["default"])
    return {k: attributes[k] for k in keep if attributes and k in attributes and attributes[k] is not None}


def history_rows(history: list[list[dict[str, Any]]], after: dt.datetime | None) -> list[dict[str, Any]]:
    """Flatten the history API answer into loader rows. States at or before `after` are dropped
    (they are the 'state at the start of the window' Home Assistant repeats, already stored)."""
    rows = []
    for series in history or []:
        for s in series or []:
            eid = s.get("entity_id")
            lu = s.get("last_updated") or s.get("last_changed")
            if not eid or not lu:
                continue
            updated = parse_ha_time(lu)
            if after is not None and updated <= after:
                continue
            changed = parse_ha_time(s.get("last_changed") or lu)
            rows.append({"e": eid, "s": None if s.get("state") is None else str(s.get("state"))[:255],
                         "a": slim_attributes(eid, s.get("attributes")), "c": iso_ms(changed), "u": iso_ms(updated)})
    rows.sort(key=lambda r: (r["u"], r["e"]))
    return rows


def chunks(rows: list[dict[str, Any]], size: int = CHUNK_ROWS) -> Iterable[list[dict[str, Any]]]:
    for i in range(0, len(rows), size):
        yield rows[i:i + size]


def day_windows(start: dt.datetime, end: dt.datetime, step: dt.timedelta = dt.timedelta(days=1)):
    t = start
    while t < end:
        yield t, min(t + step, end)
        t = t + step


def history_url(base: str, start: dt.datetime, end: dt.datetime, entities: list[str]) -> str:
    def z(t: dt.datetime) -> str:
        return urllib.parse.quote(t.replace(tzinfo=dt.timezone.utc).isoformat(timespec="seconds"), safe=":")
    q = urllib.parse.urlencode({"end_time": end.replace(tzinfo=dt.timezone.utc).isoformat(timespec="seconds"),
                                "filter_entity_id": ",".join(entities), "significant_changes_only": "0"})
    return f"{base}/api/history/period/{z(start)}?{q}"


# ---------------------------------------------------------------------------
# Talking to Home Assistant and SQL Server
# ---------------------------------------------------------------------------

class HomeAssistant:
    def __init__(self, ip: str, token: str, http: Callable[..., Any] = hbcommon.http_json):
        self.base = f"http://{ip}:8123"
        self.headers = {"Authorization": f"Bearer {token}"}
        self.http = http

    def states(self) -> dict[str, dict[str, Any]]:
        return {s["entity_id"]: s for s in self.http("GET", self.base + "/api/states", headers=self.headers, timeout=60)}

    def history(self, start: dt.datetime, end: dt.datetime, entities: list[str]) -> list[list[dict[str, Any]]]:
        return self.http("GET", history_url(self.base, start, end, entities), headers=self.headers, timeout=180) or []


def climate_settings(env: dict[str, str]) -> dict[str, Any]:
    p = Path(env.get("HB_HA_STATE", "/var/lib/homebase/ha-setup.json"))
    try:
        return (json.loads(p.read_text()) or {}).get("climate") or {}
    except (FileNotFoundError, json.JSONDecodeError, PermissionError):
        return {}


def skipped(reason: str) -> dict[str, Any]:
    """Nothing to load yet: recorded so the health check can say why."""
    prev = hbcommon.read_status("portfolio-climate") or {}
    st = {"ok": True, "skipped": reason, "finished": int(time.time()), "last_success": prev.get("last_success")}
    hbcommon.write_status("portfolio-climate", st)
    return st


def run(env: dict[str, str] | None = None, srv: SqlServer | None = None, ha: HomeAssistant | None = None,
        now: dt.datetime | None = None, full_days: int | None = None) -> dict[str, Any]:
    env = env if env is not None else hbcommon.load_env()
    if env.get("HB_SQL") != "1":
        return {"ok": True, "skipped": "SQL Server is not set up"}
    if not env.get("HB_HA_IP") or not hbcommon.read_secret("ha-token"):
        return skipped("Home Assistant is not set up")
    srv = srv or SqlServer(env)
    who = Login("etl", hbsql.check_password(hbcommon.read_secret("mssql-etl-password") or ""), DATABASE)
    ha = ha or HomeAssistant(env["HB_HA_IP"], hbcommon.read_secret("ha-token") or "")
    now = now or dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)

    plan = entity_plan(climate_settings(env), ha.states())
    entities = plan_entities(plan)
    if not entities:
        return skipped("no climate entities in Home Assistant yet (ha-setup climate setup)")
    mapped = srv.call(who, "etl.usp_set_entities", payload=plan)

    wm = (srv.call(who, "etl.usp_get_watermark") or {}).get("last_updated_utc")
    if full_days:
        start, after = now - dt.timedelta(days=full_days), None
    elif wm:
        last = dt.datetime.fromisoformat(wm)
        start, after = last - OVERLAP, last - OVERLAP
    else:
        start, after = now - dt.timedelta(days=FIRST_RUN_DAYS), None

    received = inserted = 0
    for w0, w1 in day_windows(start, now):
        # Each answer starts with every entity's state as of w0; only the very first window of a
        # first run keeps those (they are the starting values), later ones were stored already.
        rows = history_rows(ha.history(w0, w1, entities), after if w0 == start else w0)
        for part in chunks(rows):
            res = srv.call(who, "etl.usp_ingest_ha_states", payload=part, window_start=w0, window_end=w1) or {}
            received += int(res.get("rows_received") or 0)
            inserted += int(res.get("rows_inserted") or 0)

    refreshed = srv.call(who, "etl.usp_refresh_climate", from_utc=start - dt.timedelta(minutes=5), to_utc=now)
    st = {"ok": True, "finished": int(time.time()), "window_start": iso_ms(start), "window_end": iso_ms(now),
          "rows_received": received, "rows_inserted": inserted, "entities": len(entities),
          "metrics": len(plan["metrics"]), "refresh": refreshed, "mapping": mapped}
    st["last_success"] = st["finished"]
    hbcommon.write_status("portfolio-climate", st)
    return st
