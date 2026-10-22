"""SQL Server helpers for the portfolio tools (stdlib only).

SQL Server runs in the "mssql" container (docker-compose profile "sql"). Everything talks to it
with Microsoft's sqlcmd inside that container:

  * scripts are written to the shared stage folder (HB_SQL_DIR/stage on the host, which the
    container sees as /var/opt/mssql/stage), run with "sqlcmd -i", then deleted
  * passwords travel in the SQLCMDPASSWORD environment variable (docker exec -e NAME passes
    the value without putting it on any command line)
  * results come back as one JSON document per line, marked with @@JSON@@ or @@ROW@@
"""

from __future__ import annotations

import datetime as dt
import decimal
import hashlib
import json
import os
import re
import secrets
import string
import subprocess
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable

SQLCMD_PATHS = ("/opt/mssql-tools18/bin/sqlcmd", "/opt/mssql-tools/bin/sqlcmd")
CONTAINER_STAGE = "/var/opt/mssql/stage"
MSSQL_UID = 10001
MARK_JSON = "@@JSON@@"
MARK_ROW = "@@ROW@@"
DEFAULT_SQL_DIR = "/var/lib/homebase-sql"

IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
QNAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?$")
PASSWORD_RE = re.compile(r"^[A-Za-z0-9_\-]{12,128}$")


class SqlError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# Literals and names
# ---------------------------------------------------------------------------

def ident(name: str) -> str:
    if not IDENT_RE.match(name or ""):
        raise ValueError(f"not a plain SQL name: {name!r}")
    return name


def qname(name: str) -> str:
    if not QNAME_RE.match(name or ""):
        raise ValueError(f"not a plain SQL name: {name!r}")
    return name


def n_literal(value: str) -> str:
    return "N'" + str(value).replace("'", "''") + "'"


def sql_value(value: Any) -> str:
    """A Python value as a T-SQL literal for procedure parameters."""
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, (float, decimal.Decimal)):
        return format(decimal.Decimal(str(value)), "f")
    if isinstance(value, dt.datetime):
        return "'" + value.replace(tzinfo=None).isoformat(timespec="milliseconds") + "'"
    if isinstance(value, dt.date):
        return "'" + value.isoformat() + "'"
    if isinstance(value, (dict, list)):
        return n_literal(json_lines(value))
    return n_literal(str(value))


def json_lines(value: Any) -> str:
    """JSON with one array element per line. sqlcmd reads scripts line by line; short lines that
    always start with [ { , or ] can never look like GO or a sqlcmd command."""
    if isinstance(value, list):
        if not value:
            return "[]"
        return "[\n" + ",\n".join(json.dumps(v, ensure_ascii=False, separators=(",", ":")) for v in value) + "\n]"
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def make_password(length: int = 32) -> str:
    """Random password that always meets SQL Server's policy (upper, lower, digit, symbol)."""
    alphabet = string.ascii_letters + string.digits
    while True:
        core = "".join(secrets.choice(alphabet) for _ in range(length))
        pw = core[:8] + "-" + core[8:16] + "-" + core[16:]
        if any(c.isupper() for c in pw) and any(c.islower() for c in pw) and any(c.isdigit() for c in pw):
            return pw


def check_password(pw: str) -> str:
    if not PASSWORD_RE.match(pw or ""):
        raise ValueError("passwords may only use letters, digits, - and _ (12+ characters)")
    return pw


# ---------------------------------------------------------------------------
# Deploying object scripts
# ---------------------------------------------------------------------------

GO_RE = re.compile(r"^\s*GO\s*$", re.IGNORECASE)
CREATE_RE = re.compile(
    r"^CREATE\s+(?:OR\s+ALTER\s+)?(?:(UNIQUE)\s+)?(?:(CLUSTERED|NONCLUSTERED)\s+)?(?:(COLUMNSTORE)\s+)?"
    r"(SCHEMA|TABLE|INDEX|VIEW|PROCEDURE|PROC|FUNCTION|TRIGGER)\b", re.IGNORECASE)
NAME_PART = r"(?:\[[^\]]+\]|[A-Za-z_][A-Za-z0-9_]*)"
TWO_PART = rf"({NAME_PART}(?:\s*\.\s*{NAME_PART})?)"


def split_batches(text: str) -> list[str]:
    batches: list[str] = []
    buf: list[str] = []
    for line in text.replace("\r\n", "\n").split("\n"):
        if GO_RE.match(line):
            if "\n".join(buf).strip():
                batches.append("\n".join(buf).strip("\n"))
            buf = []
        else:
            buf.append(line)
    if "\n".join(buf).strip():
        batches.append("\n".join(buf).strip("\n"))
    return batches


def leading_comment_length(sql: str) -> int:
    """Length of the whitespace/comments before the first statement."""
    i = 0
    n = len(sql)
    while i < n:
        if sql[i].isspace():
            i += 1
        elif sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j < 0 else j + 1
        elif sql.startswith("/*", i):
            depth = 0
            while i < n:
                if sql.startswith("/*", i):
                    depth += 1
                    i += 2
                elif sql.startswith("*/", i):
                    depth -= 1
                    i += 2
                    if depth == 0:
                        break
                else:
                    i += 1
        else:
            break
    return i


def _clean_name(raw: str) -> str:
    parts = [p.strip().strip("[]") for p in raw.split(".")]
    return ".".join(parts)


def make_idempotent(batch: str) -> tuple[str, str, str]:
    """Rewrite one CREATE batch so it can run again safely. Returns (sql, kind, name)."""
    start = leading_comment_length(batch)
    body = batch[start:]
    m = CREATE_RE.match(body)
    if not m:
        raise ValueError("each batch must be a single CREATE statement:\n" + body[:200])
    kind = m.group(4).upper()
    if kind == "PROC":
        kind = "PROCEDURE"
    if kind == "SCHEMA":
        nm = re.match(rf"CREATE\s+SCHEMA\s+({NAME_PART})", body, re.IGNORECASE)
        name = _clean_name(nm.group(1))
        stmt = body.strip().rstrip(";")
        return (f"IF SCHEMA_ID({n_literal(name)}) IS NULL\n    EXEC({n_literal(stmt)});", kind, name)
    if kind == "TABLE":
        nm = re.match(rf"CREATE\s+TABLE\s+{TWO_PART}", body, re.IGNORECASE)
        name = _clean_name(nm.group(1))
        return (f"IF OBJECT_ID({n_literal(name)}, N'U') IS NULL\nBEGIN\n{body.strip()}\nEND;", kind, name)
    if kind == "INDEX":
        nm = re.match(rf"CREATE\s+(?:UNIQUE\s+)?(?:(?:CLUSTERED|NONCLUSTERED)\s+)?(?:COLUMNSTORE\s+)?INDEX\s+"
                      rf"({NAME_PART})\s+ON\s+{TWO_PART}", body, re.IGNORECASE)
        index, table = _clean_name(nm.group(1)), _clean_name(nm.group(2))
        return (f"IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = {n_literal(index)} "
                f"AND object_id = OBJECT_ID({n_literal(table)}))\nBEGIN\n{body.strip()}\nEND;", kind, f"{table}.{index}")
    nm = re.match(rf"CREATE\s+(?:OR\s+ALTER\s+)?(?:VIEW|PROCEDURE|PROC|FUNCTION|TRIGGER)\s+{TWO_PART}", body, re.IGNORECASE)
    name = _clean_name(nm.group(1))
    if not re.match(r"CREATE\s+OR\s+ALTER\b", body, re.IGNORECASE):
        body = re.sub(r"^CREATE\b", "CREATE OR ALTER", body, count=1, flags=re.IGNORECASE)
    return (batch[:start] + body, kind, name)


def deploy_files(project_dirs: Iterable[Path]) -> list[Path]:
    """The .sql files of the given folders, in deployment order (by file name)."""
    files: list[Path] = []
    for d in project_dirs:
        files += sorted(Path(d).glob("*.sql"))
    return sorted(files, key=lambda p: p.name)


def build_deploy_script(database: str, files: list[Path], version: str) -> tuple[str, int]:
    """One sqlcmd script: create the database if needed, then every object, then the
    post-deploy procedure and a deploy_log row."""
    db = ident(database)
    out = [
        "SET NOCOUNT ON;",
        f"IF DB_ID({n_literal(db)}) IS NULL",
        "BEGIN",
        f"    CREATE DATABASE [{db}];",
        f"    ALTER DATABASE [{db}] SET RECOVERY SIMPLE;",
        f"    ALTER DATABASE [{db}] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;",
        "END;",
        "GO",
        f"USE [{db}];",
        "GO",
    ]
    count = 0
    for f in files:
        for batch in split_batches(f.read_text(encoding="utf-8")):
            sql, _kind, _name = make_idempotent(batch)
            out += [f"-- {f.name}", sql, "GO"]
            count += 1
    out += [
        "IF OBJECT_ID(N'etl.usp_post_deploy', N'P') IS NOT NULL EXEC etl.usp_post_deploy;",
        "GO",
        "IF OBJECT_ID(N'dbo.deploy_log', N'U') IS NULL",
        "    CREATE TABLE dbo.deploy_log (deployed_utc datetime2(0) NOT NULL CONSTRAINT DF_deploy_log_utc "
        "DEFAULT (SYSUTCDATETIME()), kit_version varchar(40) NOT NULL, object_count int NOT NULL);",
        "GO",
        f"INSERT INTO dbo.deploy_log (kit_version, object_count) VALUES ({n_literal(version)}, {count});",
        "GO",
    ]
    return "\n".join(out) + "\n", count


def files_version(files: list[Path]) -> str:
    h = hashlib.sha256()
    for f in files:
        h.update(f.name.encode())
        h.update(f.read_bytes())
    return h.hexdigest()[:12]


# ---------------------------------------------------------------------------
# Running scripts in the container
# ---------------------------------------------------------------------------

@dataclass
class Login:
    name: str
    password: str
    database: str = "master"

    def to(self, database: str) -> "Login":
        return Login(self.name, self.password, database)


def parse_marked(lines: Iterable[str], mark: str) -> list[Any]:
    out = []
    for line in lines:
        s = line.strip()
        if s.startswith(mark):
            out.append(json.loads(s[len(mark):]))
    return out


class SqlServer:
    def __init__(self, env: dict[str, str], runner: Callable[..., Any] = subprocess.run,
                 chown: bool | None = None):
        self.env = env
        self.data_dir = Path(env.get("HB_SQL_DIR") or DEFAULT_SQL_DIR)
        self.stage_dir = self.data_dir / "stage"
        self._run = runner
        self._chown = (os.geteuid() == 0) if chown is None else chown
        self._container: str | None = None
        self._sqlcmd: str | None = None

    # -- container --
    def container(self) -> str:
        if self._container:
            return self._container
        r = self._run(["docker", "ps", "-q", "--filter", "label=com.docker.compose.project=homebase",
                       "--filter", "label=com.docker.compose.service=mssql"],
                      capture_output=True, encoding="utf-8", errors="replace", timeout=30)
        ids = [x for x in (r.stdout or "").split() if x]
        if r.returncode != 0 or not ids:
            raise SqlError("SQL Server isn't running (the mssql container is not up)")
        self._container = ids[0]
        return self._container

    def sqlcmd(self) -> str:
        if self._sqlcmd:
            return self._sqlcmd
        cid = self.container()
        for p in SQLCMD_PATHS:
            r = self._run(["docker", "exec", cid, "test", "-x", p], capture_output=True, encoding="utf-8",
                          errors="replace", timeout=30)
            if r.returncode == 0:
                self._sqlcmd = p
                return p
        raise SqlError("sqlcmd was not found in the SQL Server container")

    # -- scripts --
    def execute(self, script: str, login: Login, variables: dict[str, str] | None = None,
                timeout: int = 7200, headers: bool = False) -> list[str]:
        """Run a script; returns stdout lines. variables become sqlcmd $(NAME) values (passed
        through the environment); without variables, $( ) is left alone (-x). headers=True
        prints column names and tab-separated columns (for people, not for parsing)."""
        self.stage_dir.mkdir(parents=True, exist_ok=True)
        name = f"hb-{uuid.uuid4().hex}.sql"
        host = self.stage_dir / name
        fd = os.open(host, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(script)
        if self._chown:
            os.chown(host, MSSQL_UID, 0)
        env = dict(os.environ)
        env["SQLCMDPASSWORD"] = login.password
        cmd = ["docker", "exec", "-e", "SQLCMDPASSWORD"]
        for k, v in (variables or {}).items():
            ident(k)
            env[k] = v
            cmd += ["-e", k]
        cmd += [self.container(), self.sqlcmd(), "-S", "localhost", "-U", login.name, "-d", login.database,
                "-C", "-b", "-r", "1", "-f", "65001", "-y", "0", "-w", "65535", "-l", "30", "-t", "0", "-X"]
        # no "-h -1" without headers: sqlcmd refuses it together with -y 0 (no truncation), and the
        # header lines don't matter, since results are read by their marker (parse_marked)
        cmd += ["-s", "\t"] if headers else []
        if not variables:
            cmd.append("-x")
        cmd += ["-i", f"{CONTAINER_STAGE}/{name}"]
        try:
            r = self._run(cmd, env=env, capture_output=True, encoding="utf-8", errors="replace", timeout=timeout)
        finally:
            try:
                host.unlink()
            except FileNotFoundError:
                pass
        if r.returncode != 0:
            msg = "\n".join(x for x in ((r.stderr or "") + "\n" + (r.stdout or "")).splitlines()
                            if x.strip() and not x.startswith(("Changed database context", "Changed language")))
            raise SqlError(msg.strip()[-2000:] or f"sqlcmd failed (exit {r.returncode})")
        return (r.stdout or "").splitlines()

    def call(self, login: Login, procedure: str, **params: Any) -> Any:
        """EXEC a procedure that has an @result nvarchar(max) OUTPUT parameter (JSON)."""
        args = [f"@{ident(k)} = {sql_value(v)}" for k, v in params.items()]
        args.append("@result = @r OUTPUT")
        script = ("SET NOCOUNT ON;\nDECLARE @r nvarchar(max);\n"
                  f"EXEC {qname(procedure)} " + ",\n    ".join(args) + ";\n"
                  f"SELECT N'{MARK_JSON}' + COALESCE(@r, N'null');\n")
        found = parse_marked(self.execute(script, login), MARK_JSON)
        if not found:
            raise SqlError(f"{procedure} returned nothing")
        return found[-1]

    def exec_proc(self, login: Login, procedure: str, **params: Any) -> None:
        args = ", ".join(f"@{ident(k)} = {sql_value(v)}" for k, v in params.items())
        self.execute(f"SET NOCOUNT ON;\nEXEC {qname(procedure)} {args};\n", login)

    def rows(self, login: Login, source: str, columns: list[str], order_by: list[str] | None = None,
             where: str = "") -> list[dict[str, Any]]:
        """SELECT columns FROM source as a list of dicts (one JSON object per output line)."""
        cols = ", ".join(f"q.{ident(c)} AS {ident(c)}" for c in columns)
        order = (" ORDER BY " + ", ".join(f"q.{ident(c)}" for c in order_by)) if order_by else ""
        script = ("SET NOCOUNT ON;\n"
                  f"SELECT N'{MARK_ROW}' + (SELECT {cols} FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES)\n"
                  f"FROM {qname(source)} AS q{(' WHERE ' + where) if where else ''}{order};\n")
        return parse_marked(self.execute(script, login), MARK_ROW)

    def scalar_json(self, login: Login, select_sql: str) -> Any:
        """Runs 'SELECT ... FOR JSON ...' and returns the parsed document (keep it small)."""
        script = ("SET NOCOUNT ON;\nDECLARE @r nvarchar(max) = (" + select_sql + ");\n"
                  f"SELECT N'{MARK_JSON}' + COALESCE(@r, N'null');\n")
        found = parse_marked(self.execute(script, login), MARK_JSON)
        return found[-1] if found else None
