#!/usr/bin/env python3
"""Generate docs/PARAMETERS.md and docs/SCHEMA.md from repository sources.

Standard library only, no network, no database. The output is deterministic: two runs over
the same tree produce byte-identical files. `--check` regenerates in memory and fails when
the committed file differs.

Sources
  params  modules/*/seeds/params.yaml (+ optional packs/base/generated/param_provenance.md
          cross-check)
  schema  modules/*/migrations/*.sql + ops/migrations/contract-auto.txt
"""

import argparse
import difflib
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


class SourceError(Exception):
    """A source file exists but cannot be parsed. Always carries the file name."""


def fail(path, message):
    raise SourceError(f"{path}: {message}")


# ---------------------------------------------------------------------------
# Minimal YAML subset parser
#
# The seed files use block sequences of mappings, nested one-level mappings (provenance,
# schema) and flow collections. This parser supports exactly that subset; anything outside
# it raises SourceError with the offending line, so a new construct cannot be skipped.
# ---------------------------------------------------------------------------

KEY_RE = re.compile(r"^([^:#\s][^:]*?):(?:\s+(.*))?$")


def _strip_comment(line):
    out = []
    i = 0
    quote = None
    while i < len(line):
        ch = line[i]
        if quote == "'":
            out.append(ch)
            if ch == "'":
                if i + 1 < len(line) and line[i + 1] == "'":
                    out.append("'")
                    i += 2
                    continue
                quote = None
            i += 1
            continue
        if quote == '"':
            out.append(ch)
            if ch == "\\" and i + 1 < len(line):
                out.append(line[i + 1])
                i += 2
                continue
            if ch == '"':
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            out.append(ch)
            i += 1
            continue
        if ch == "#" and (i == 0 or line[i - 1] in " \t"):
            break
        out.append(ch)
        i += 1
    return "".join(out).rstrip()


def _convert_plain(text):
    if text in ("true", "True"):
        return True
    if text in ("false", "False"):
        return False
    if text in ("null", "Null", "~", ""):
        return None
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    if re.fullmatch(r"-?\d+\.\d+", text):
        return float(text)
    return text


def _parse_quoted(text, pos, path, lineno):
    quote = text[pos]
    i = pos + 1
    buf = []
    while i < len(text):
        ch = text[i]
        if quote == "'":
            if ch == "'":
                if i + 1 < len(text) and text[i + 1] == "'":
                    buf.append("'")
                    i += 2
                    continue
                return "".join(buf), i + 1
            buf.append(ch)
            i += 1
            continue
        if ch == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            buf.append({"n": "\n", "t": "\t"}.get(nxt, nxt))
            i += 2
            continue
        if ch == '"':
            return "".join(buf), i + 1
        buf.append(ch)
        i += 1
    fail(path, f"line {lineno}: unterminated string")


def _skip_ws(text, pos):
    while pos < len(text) and text[pos] in " \t":
        pos += 1
    return pos


def _parse_flow(text, pos, path, lineno):
    pos = _skip_ws(text, pos)
    if pos >= len(text):
        fail(path, f"line {lineno}: expected a value")
    ch = text[pos]
    if ch == "{":
        result = {}
        pos += 1
        while True:
            pos = _skip_ws(text, pos)
            if pos >= len(text):
                fail(path, f"line {lineno}: unterminated flow mapping")
            if text[pos] == "}":
                return result, pos + 1
            if text[pos] in "'\"":
                key, pos = _parse_quoted(text, pos, path, lineno)
            else:
                start = pos
                while pos < len(text) and text[pos] not in ":}":
                    pos += 1
                key = text[start:pos].strip()
            pos = _skip_ws(text, pos)
            if pos >= len(text) or text[pos] != ":":
                fail(path, f"line {lineno}: expected ':' in flow mapping")
            pos += 1
            value, pos = _parse_flow(text, pos, path, lineno)
            result[key] = value
            pos = _skip_ws(text, pos)
            if pos < len(text) and text[pos] == ",":
                pos += 1
                continue
            if pos < len(text) and text[pos] == "}":
                return result, pos + 1
            fail(path, f"line {lineno}: expected ',' or '}}' in flow mapping")
    if ch == "[":
        result = []
        pos += 1
        while True:
            pos = _skip_ws(text, pos)
            if pos >= len(text):
                fail(path, f"line {lineno}: unterminated flow sequence")
            if text[pos] == "]":
                return result, pos + 1
            value, pos = _parse_flow(text, pos, path, lineno)
            result.append(value)
            pos = _skip_ws(text, pos)
            if pos < len(text) and text[pos] == ",":
                pos += 1
                continue
            if pos < len(text) and text[pos] == "]":
                return result, pos + 1
            fail(path, f"line {lineno}: expected ',' or ']' in flow sequence")
    if ch in "'\"":
        return _parse_quoted(text, pos, path, lineno)
    start = pos
    while pos < len(text) and text[pos] not in ",}]":
        pos += 1
    return _convert_plain(text[start:pos].strip()), pos


def _parse_inline(text, path, lineno):
    stripped = text.strip()
    if not stripped:
        return None
    if stripped[0] not in "{['\"":
        return _convert_plain(stripped)
    value, pos = _parse_flow(stripped, 0, path, lineno)
    if _skip_ws(stripped, pos) != len(stripped):
        fail(path, f"line {lineno}: trailing content after value")
    return value


def _rows(raw_lines, path):
    rows = []
    for lineno, raw in enumerate(raw_lines, 1):
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            fail(path, f"line {lineno}: tab indentation is not supported")
        stripped = _strip_comment(raw)
        if not stripped.strip():
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        rows.append([indent, stripped.strip(), lineno])
    return rows


def _parse_map(rows, idx, indent, path, initial=None):
    result = dict(initial or [])
    while idx < len(rows):
        ind, text, lineno = rows[idx]
        if ind < indent:
            break
        if ind > indent:
            fail(path, f"line {lineno}: unexpected indentation")
        if text == "-" or text.startswith("- "):
            break
        match = KEY_RE.match(text)
        if not match:
            fail(path, f"line {lineno}: expected 'key: value'")
        key, rest = match.group(1).strip(), (match.group(2) or "").strip()
        idx += 1
        if rest:
            result[key] = _parse_inline(rest, path, lineno)
        elif idx < len(rows) and rows[idx][0] > indent:
            result[key], idx = _parse_block(rows, idx, rows[idx][0], path)
        else:
            result[key] = None
    return result, idx


def _parse_seq(rows, idx, indent, path):
    result = []
    while idx < len(rows):
        ind, text, lineno = rows[idx]
        if ind != indent or not (text == "-" or text.startswith("- ")):
            break
        item = text[1:].strip()
        idx += 1
        if not item:
            if idx < len(rows) and rows[idx][0] > indent:
                value, idx = _parse_block(rows, idx, rows[idx][0], path)
            else:
                value = None
            result.append(value)
            continue
        match = KEY_RE.match(item)
        if match:
            key, rest = match.group(1).strip(), (match.group(2) or "").strip()
            first = {}
            if rest:
                first[key] = _parse_inline(rest, path, lineno)
            elif idx < len(rows) and rows[idx][0] > indent + 1:
                first[key], idx = _parse_block(rows, idx, rows[idx][0], path)
            else:
                first[key] = None
            if idx < len(rows) and rows[idx][0] > indent:
                tail_indent = rows[idx][0]
                tail, idx = _parse_map(rows, idx, tail_indent, path)
                for tail_key, tail_value in tail.items():
                    if tail_key in first:
                        fail(path, f"line {lineno}: duplicate key '{tail_key}'")
                    first[tail_key] = tail_value
            result.append(first)
            continue
        if item[0] not in "{['\"":
            result.append(_convert_plain(item))
            continue
        value, pos = _parse_flow(item, 0, path, lineno)
        if _skip_ws(item, pos) != len(item):
            fail(path, f"line {lineno}: trailing content after sequence item")
        result.append(value)
    return result, idx


def _parse_block(rows, idx, indent, path):
    if rows[idx][0] != indent:
        fail(path, f"line {rows[idx][2]}: inconsistent indentation")
    if rows[idx][1] == "-" or rows[idx][1].startswith("- "):
        return _parse_seq(rows, idx, indent, path)
    return _parse_map(rows, idx, indent, path)


def load_yaml(path):
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(path, f"cannot read: {exc}")
    rows = _rows(text.splitlines(), path)
    if not rows:
        return None
    first = rows[0][1]
    if not (first == "-" or first.startswith("- ") or KEY_RE.match(first)):
        if len(rows) != 1:
            fail(path, f"line {rows[1][2]}: unexpected content after a flow value")
        return _parse_inline(first, path, rows[0][2])
    value, idx = _parse_block(rows, 0, rows[0][0], path)
    if idx != len(rows):
        fail(path, f"line {rows[idx][2]}: unparsed content")
    return value


# ---------------------------------------------------------------------------
# Parameter catalogue
# ---------------------------------------------------------------------------

SECRET_PATTERNS = (
    re.compile(r"-----BEGIN [A-Z ]+-----"),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"),
    re.compile(r"sk-[A-Za-z0-9]{16,}"),
    re.compile(r"^[A-Za-z0-9+/]{40,}={0,2}$"),
    re.compile(r"^[0-9a-fA-F]{40,}$"),
)


def assert_not_secret(path, key, value):
    if isinstance(value, dict):
        for nested in value.values():
            assert_not_secret(path, key, nested)
        return
    if isinstance(value, list):
        for nested in value:
            assert_not_secret(path, key, nested)
        return
    if not isinstance(value, str):
        return
    for pattern in SECRET_PATTERNS:
        if pattern.search(value):
            fail(path, f"{key}: seeded value looks like a secret; refusing to publish")


def load_parameters(root):
    seed_paths = sorted(root.glob("modules/*/seeds/params.yaml"))
    if not seed_paths:
        fail(root / "modules", "no seeds/params.yaml files found")
    params = []
    seen = {}
    for path in seed_paths:
        module = path.parent.parent.name
        data = load_yaml(path)
        if data is None:
            fail(path, "empty seed file")
        if not isinstance(data, list):
            fail(path, "top level must be a sequence of parameter definitions")
        for entry in data:
            if not isinstance(entry, dict):
                fail(path, "parameter definition must be a mapping")
            key = entry.get("key")
            if not isinstance(key, str) or not key:
                fail(path, "definition without a string `key`")
            if key in seen:
                fail(path, f"{key}: duplicate definition (first in {seen[key]})")
            seen[key] = path
            value_type = entry.get("type")
            if not isinstance(value_type, str) or not value_type:
                fail(path, f"{key}: missing `type`")
            scopes = entry.get("scopes")
            if not isinstance(scopes, list) or not scopes:
                fail(path, f"{key}: missing `scopes`")
            provenance = entry.get("provenance")
            if not isinstance(provenance, dict):
                fail(path, f"{key}: missing `provenance` mapping")
            klass = provenance.get("class")
            if not isinstance(klass, str) or not klass:
                fail(path, f"{key}: missing `provenance.class`")
            default_pack = entry.get("default_pack")
            if default_pack is not None and not isinstance(default_pack, dict):
                fail(path, f"{key}: `default_pack` must be a mapping")
            if default_pack:
                assert_not_secret(path, key, default_pack)
            assert_not_secret(path, key, entry)
            params.append(
                {
                    "key": key,
                    "class": klass,
                    "scopes": [str(s) for s in scopes],
                    "type": value_type,
                    "schema": entry.get("schema") or {},
                    "enum": entry.get("enum"),
                    "compliance": provenance.get("compliance"),
                    "packs": sorted(default_pack) if default_pack else [],
                    "seeded": bool(default_pack),
                    "source": path.relative_to(root).as_posix(),
                    "module": module,
                }
            )
    params.sort(key=lambda p: p["key"])
    return params


def cross_check_catalogue(root, params):
    """If paramgen already published the provenance table, its key set must match the seeds.

    The catalogue is never a source here; it is a second witness. A mismatch means the tree
    is internally inconsistent and the docs would drift, so fail instead of guessing.
    """

    catalogue = root / "packs/base/generated/param_provenance.md"
    if not catalogue.exists():
        return 0
    keys = []
    for line in catalogue.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^\|\s*`([a-z0-9_.]+)`\s*\|", line)
        if match:
            keys.append(match.group(1))
    if not keys:
        return 0
    seed_keys = {p["key"] for p in params}
    catalogue_keys = set(keys)
    missing = sorted(seed_keys - catalogue_keys)
    extra = sorted(catalogue_keys - seed_keys)
    if missing or extra:
        details = []
        if missing:
            details.append("missing from catalogue: " + ", ".join(missing))
        if extra:
            details.append("unknown to seeds: " + ", ".join(extra))
        fail(catalogue, "parameter catalogue is out of sync (" + "; ".join(details) + ")")
    return len(keys)


def _fmt_number(value):
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    return str(value)


def format_type(param):
    value_type = param["type"]
    schema = param["schema"] if isinstance(param["schema"], dict) else {}
    if value_type == "enum":
        values = param["enum"] or schema.get("enum") or []
        return "enum: " + "|".join(str(v) for v in values) if values else "enum"
    if value_type == "json":
        nested = schema.get("type")
        return f"json ({nested})" if nested else "json"
    if value_type == "integer":
        low, high = schema.get("minimum"), schema.get("maximum")
        if low is not None and high is not None:
            return f"integer {_fmt_number(low)}..{_fmt_number(high)}"
        if low is not None:
            return f"integer >= {_fmt_number(low)}"
        if high is not None:
            return f"integer <= {_fmt_number(high)}"
        return "integer"
    if value_type in ("money", "rate"):
        low, high = schema.get("minimum"), schema.get("maximum")
        if low is not None and high is not None:
            return f"{value_type} {_fmt_number(low)}..{_fmt_number(high)}"
        if low is not None:
            return f"{value_type} >= {_fmt_number(low)}"
        if high is not None:
            return f"{value_type} <= {_fmt_number(high)}"
        return value_type
    if value_type == "string":
        low, high = schema.get("minLength"), schema.get("maxLength")
        if low is not None and high is not None:
            return f"string {_fmt_number(low)}..{_fmt_number(high)}"
        if low is not None:
            return f"string >= {_fmt_number(low)} chars"
        if high is not None:
            return f"string <= {_fmt_number(high)} chars"
        return "string"
    return value_type


def render_parameters(root, params, catalogue_count):
    modules = sorted({p["module"] for p in params})
    classes = {}
    for param in params:
        classes[param["class"]] = classes.get(param["class"], 0) + 1
    marked = sum(1 for p in params if p["compliance"])
    unseeded = sum(1 for p in params if not p["seeded"])

    lines = [
        "<!-- GENERATED FILE: do not edit by hand. -->",
        "<!-- Source: modules/*/seeds/params.yaml -->",
        "<!-- Regenerate: python3 tools/docsgen/docsgen.py params -->",
        "<!-- Drift check: python3 tools/docsgen/docsgen.py params --check -->",
        "",
        "# Parameters",
        "",
        "Every policy, rate and limit is read from the database; no business value lives in",
        "code (spec §10). This page is generated from the seed definitions and intentionally",
        "does not repeat seeded values, so approving a new value does not touch this file.",
        "",
        "- Definitions: "
        f"**{len(params)}** across **{len(modules)}** modules "
        f"({', '.join('`' + m + '`' for m in modules)}).",
        f"- Definitions with no seeded value (callers must fail fast): **{unseeded}**.",
        f"- Definitions carrying a review marker: **{marked}**.",
    ]
    if catalogue_count:
        lines.append(
            f"- Cross-checked against `packs/base/generated/param_provenance.md` "
            f"({catalogue_count} keys)."
        )
    lines.extend(
        [
            "",
            "`Class` is the provenance class from `paramgen` (D-095). `Scope` lists the scopes a",
            "value may be stored in. `Seed pack` names the pack that ships a starting value; `-`",
            "means the definition has none. The marker column repeats `provenance.compliance`",
            "verbatim (`NEEDS-COMPLIANCE-REVIEW`, `HUMAN-REVIEW-REQUIRED`, or `-`), so",
            "`NEEDS-COMPLIANCE-REVIEW` always means the value is provisional and must not be",
            "quoted as a regulatory requirement.",
            "",
            "| Key | Class | Scope | Unit/type | Seed pack | Value seeded | Review marker | Source |",
            "|---|---|---|---|---|---|---|---|",
        ]
    )
    for param in params:
        marker = param["compliance"] or "-"
        lines.append(
            "| "
            + " | ".join(
                [
                    f"`{param['key']}`",
                    param["class"],
                    ", ".join(param["scopes"]),
                    format_type(param).replace("|", "\\|"),
                    ", ".join(param["packs"]) or "-",
                    "yes" if param["seeded"] else "no",
                    f"`{marker}`" if marker != "-" else "-",
                    f"`{param['source']}`",
                ]
            )
            + " |"
        )
    lines.extend(["", "## Definitions per class", "", "| Class | Definitions |", "|---|---|"])
    for klass in sorted(classes):
        lines.append(f"| {klass} | {classes[klass]} |")
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# SQL parsing
# ---------------------------------------------------------------------------

DOLLAR_RE = re.compile(r"\$([A-Za-z_0-9]*)\$")


def _blank_comments(sql):
    out = list(sql)
    i = 0
    length = len(sql)
    while i < length:
        ch = sql[i]
        if ch == "-" and i + 1 < length and sql[i + 1] == "-":
            j = i
            while j < length and sql[j] != "\n":
                out[j] = " "
                j += 1
            i = j
            continue
        if ch == "/" and i + 1 < length and sql[i + 1] == "*":
            j = i
            while j < length and not (sql[j] == "*" and j + 1 < length and sql[j + 1] == "/"):
                if sql[j] != "\n":
                    out[j] = " "
                j += 1
            for k in range(j, min(j + 2, length)):
                if sql[k] != "\n":
                    out[k] = " "
            i = min(j + 2, length)
            continue
        if ch == "'":
            j = i + 1
            while j < length:
                if sql[j] == "'":
                    if j + 1 < length and sql[j + 1] == "'":
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            i = j
            continue
        if ch == "$":
            match = DOLLAR_RE.match(sql, i)
            if match:
                tag = match.group(0)
                end = sql.find(tag, match.end())
                if end == -1:
                    i = length
                else:
                    i = end + len(tag)
                continue
        i += 1
    return "".join(out)


def split_statements(clean):
    statements = []
    start = 0
    i = 0
    length = len(clean)
    depth = 0
    while i < length:
        ch = clean[i]
        if ch == "'":
            i += 1
            while i < length:
                if clean[i] == "'":
                    if i + 1 < length and clean[i + 1] == "'":
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        if ch == "$":
            match = DOLLAR_RE.match(clean, i)
            if match:
                tag = match.group(0)
                end = clean.find(tag, match.end())
                i = length if end == -1 else end + len(tag)
                continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        elif ch == ";" and depth == 0:
            statements.append((start, i + 1))
            start = i + 1
        i += 1
    if clean[start:].strip():
        statements.append((start, length))
    return statements


def split_top_level(text, separator=","):
    parts = []
    start = 0
    i = 0
    depth = 0
    length = len(text)
    while i < length:
        ch = text[i]
        if ch == "'":
            i += 1
            while i < length:
                if text[i] == "'":
                    if i + 1 < length and text[i + 1] == "'":
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        elif ch == separator and depth == 0:
            parts.append(text[start:i])
            start = i + 1
        i += 1
    parts.append(text[start:])
    return [p.strip() for p in parts if p.strip()]


def normalise(text):
    return re.sub(r"\s+", " ", text).strip()


def unquote_sql_literals(expr):
    parts = []
    i = 0
    while i < len(expr):
        if expr[i] != "'":
            i += 1
            continue
        i += 1
        buf = []
        while i < len(expr):
            if expr[i] == "'":
                if i + 1 < len(expr) and expr[i + 1] == "'":
                    buf.append("'")
                    i += 2
                    continue
                i += 1
                break
            buf.append(expr[i])
            i += 1
        parts.append("".join(buf))
    return normalise("".join(parts))


def comment_summary(text, limit=240):
    text = normalise(text)
    if not text:
        return "-"
    if len(text) > limit:
        cut = text.rfind(" ", 0, limit)
        text = text[: cut if cut > 0 else limit].rstrip() + "…"
    return text.replace("|", "\\|")


class Table:
    def __init__(self, schema, name):
        self.schema = schema
        self.name = name
        self.purpose = None
        self.constraints = {}
        self.unique_names = set()
        self.triggers = set()
        self.files = set()
        self.latest = None
        self.contract = False

    def touch(self, migration):
        self.files.add(migration)
        if self.latest is None or migration > self.latest:
            self.latest = migration

    def add_constraint(self, pg_name, kind, columns=None, reference=None):
        name = pg_name
        if name is None:
            name = self._auto_name(kind, columns)
        suffix = 1
        unique_name = name
        while unique_name in self.constraints:
            suffix += 1
            unique_name = f"{name}{suffix - 1}"
        self.constraints[unique_name] = {
            "kind": kind,
            "columns": list(columns or []),
            "reference": reference,
        }

    def _auto_name(self, kind, columns):
        # PostgreSQL auto-names constraints with the table (not the schema) as prefix.
        table = self.name
        cols = "_".join(columns or [])
        if kind == "pk":
            return f"{table}_pkey"
        if kind == "fk":
            return f"{table}_{cols}_fkey"
        if kind == "unique":
            return f"{table}_{cols}_key" if cols else f"{table}_key"
        if kind == "check":
            return f"{table}_{cols}_check" if cols else f"{table}_check"
        return f"{table}_{kind}"

    def drop_constraint(self, name):
        self.constraints.pop(name, None)

    def counts(self):
        values = list(self.constraints.values())
        return (
            sum(1 for c in values if c["kind"] == "pk"),
            sum(1 for c in values if c["kind"] == "fk"),
            len(self.unique_names)
            + sum(1 for c in values if c["kind"] == "unique"),
            sum(1 for c in values if c["kind"] == "check"),
        )

    def pk_columns(self):
        columns = []
        for constraint in self.constraints.values():
            if constraint["kind"] == "pk":
                columns.extend(constraint["columns"])
        return columns

    def fk_columns(self):
        pairs = []
        for constraint in self.constraints.values():
            if constraint["kind"] == "fk" and constraint["columns"]:
                pairs.append((constraint["columns"], constraint["reference"]))
        return pairs


CONSTRAINT_KINDS = (
    ("primary key", "pk"),
    ("foreign key", "fk"),
    ("unique", "unique"),
    ("check", "check"),
    ("exclude", "exclude"),
)


def constraint_kind(text):
    lowered = text.lstrip().lower()
    for prefix, kind in CONSTRAINT_KINDS:
        if re.match(rf"{prefix}\b", lowered):
            return kind
    return None


def parse_constraint_columns(rest, kind):
    match = re.match(r"(?:primary\s+key|foreign\s+key|unique)\s*\(([^)]*)\)", rest, re.I | re.S)
    if match:
        return [part.strip().strip('"') for part in match.group(1).split(",") if part.strip()]
    if kind == "fk":
        match = re.search(r"references\s+([a-z_][\w.]*)\s*\(([^)]*)\)", rest, re.I | re.S)
        if match:
            return [part.strip().strip('"') for part in match.group(2).split(",") if part.strip()]
    return []


def parse_reference(rest):
    match = re.search(r"REFERENCES\s+([a-z_][\w.]*)\s*\(([^)]*)\)", rest, re.I | re.S)
    if not match:
        return None
    target = match.group(1)
    columns = ", ".join(part.strip() for part in match.group(2).split(",") if part.strip())
    return f"{target}({columns})"


def parse_create_table(body, table):
    for segment in split_top_level(body):
        match = re.match(r"CONSTRAINT\s+(\w+)\s+(.*)$", segment, re.I | re.S)
        name = None
        rest = segment
        if match:
            name = match.group(1)
            rest = match.group(2)
        kind = constraint_kind(rest)
        if kind:
            columns = parse_constraint_columns(rest, kind)
            reference = parse_reference(rest) if kind == "fk" else None
            if kind == "exclude":
                continue
            table.add_constraint(name, kind, columns, reference)
            continue
        # Column definition.
        column_match = re.match(r'("?[A-Za-z_][\w]*"?)\s+', rest)
        if not column_match:
            fail(table.schema + "." + table.name, f"cannot parse column definition: {normalise(segment)}")
        column = column_match.group(1).strip('"')
        tail = rest[column_match.end():]
        if re.search(r"\bPRIMARY\s+KEY\b", tail, re.I):
            table.add_constraint(None, "pk", [column])
        reference = parse_reference(tail)
        if reference:
            table.add_constraint(None, "fk", [column], reference)
        if re.search(r"(?<!\bPRIMARY\s)\bUNIQUE\b", tail, re.I):
            table.add_constraint(None, "unique", [column])
        checks = len(re.findall(r"\bCHECK\s*\(", tail, re.I))
        for _ in range(checks):
            table.add_constraint(None, "check", [column])


def parse_alter(stmt, tables, migration):
    match = re.match(
        r"\s*ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?([a-z_]\w*)\.([a-z_]\w*)\s+(.*)$",
        stmt,
        re.I | re.S,
    )
    if not match:
        return False
    key = (match.group(1).lower(), match.group(2).lower())
    table = tables.get(key)
    if table is None:
        return True
    table.touch(migration)
    actions = split_top_level(match.group(3))
    for action in actions:
        add = re.match(r"ADD\s+CONSTRAINT\s+(\w+)\s+(.*)$", action, re.I | re.S)
        if add:
            kind = constraint_kind(add.group(2))
            if kind and kind != "exclude":
                table.add_constraint(
                    add.group(1),
                    kind,
                    parse_constraint_columns(add.group(2), kind),
                    parse_reference(add.group(2)) if kind == "fk" else None,
                )
            continue
        drop = re.match(r"DROP\s+CONSTRAINT\s+(?:IF\s+EXISTS\s+)?(\w+)", action, re.I)
        if drop:
            table.drop_constraint(drop.group(1))
            continue
        add_column = re.match(r"ADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s+(.*)$", action, re.I | re.S)
        if add_column:
            column = add_column.group(1)
            tail = add_column.group(2)
            reference = parse_reference(tail)
            if reference:
                table.add_constraint(None, "fk", [column], reference)
            for _ in range(len(re.findall(r"\bCHECK\s*\(", tail, re.I))):
                table.add_constraint(None, "check", [column])
    return True


def parse_migration(path, root, tables):
    try:
        sql = path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(path, f"cannot read: {exc}")
    clean = _blank_comments(sql)
    migration = path.name
    found_tables = 0
    kinds = []
    for start, end in split_statements(clean):
        stmt = clean[start:end]
        if not stmt.strip():
            continue
        head = normalise(stmt)
        upper = head.upper()
        if re.match(r"CREATE\s+TABLE\b", upper):
            match = re.match(
                r"\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([a-z_]\w*)\.([a-z_]\w*)\s*\(",
                stmt,
                re.I,
            )
            if not match:
                fail(path, "cannot parse CREATE TABLE statement")
            schema, name = match.group(1).lower(), match.group(2).lower()
            body_start = match.end()
            depth = 1
            i = body_start
            while i < len(stmt) and depth > 0:
                if stmt[i] == "'":
                    i += 1
                    while i < len(stmt):
                        if stmt[i] == "'":
                            if i + 1 < len(stmt) and stmt[i + 1] == "'":
                                i += 2
                                continue
                            i += 1
                            break
                        i += 1
                    continue
                if stmt[i] == "(":
                    depth += 1
                elif stmt[i] == ")":
                    depth -= 1
                i += 1
            if depth != 0:
                fail(path, f"unterminated CREATE TABLE {schema}.{name}")
            body = stmt[body_start : i - 1]
            key = (schema, name)
            if key in tables:
                table = tables[key]
            else:
                table = Table(schema, name)
                tables[key] = table
            parse_create_table(body, table)
            table.touch(migration)
            found_tables += 1
            kinds.append("create table")
            continue
        if upper.startswith("ALTER TABLE"):
            if not parse_alter(stmt, tables, migration):
                fail(path, f"cannot parse ALTER TABLE statement: {head[:80]}")
            kinds.append("alter table")
            continue
        if upper.startswith("COMMENT ON TABLE"):
            match = re.match(r"\s*COMMENT\s+ON\s+TABLE\s+([a-z_]\w*)\.([a-z_]\w*)\s+IS\s+(.*)$", stmt, re.I | re.S)
            if not match:
                fail(path, "cannot parse COMMENT ON TABLE statement")
            key = (match.group(1).lower(), match.group(2).lower())
            table = tables.get(key)
            if table is None:
                fail(path, f"comment on unknown table {key[0]}.{key[1]}")
            table.purpose = unquote_sql_literals(match.group(3))
            table.touch(migration)
            kinds.append("comment")
            continue
        if upper.startswith("COMMENT ON COLUMN"):
            match = re.match(r"\s*COMMENT\s+ON\s+COLUMN\s+([a-z_]\w*)\.([a-z_]\w*)\.", stmt, re.I)
            if match:
                table = tables.get((match.group(1).lower(), match.group(2).lower()))
                if table is not None:
                    table.touch(migration)
            kinds.append("comment")
            continue
        if upper.startswith("CREATE SCHEMA"):
            kinds.append("create schema")
            continue
        if re.match(r"CREATE\s+(UNIQUE\s+)?INDEX\b", upper):
            match = re.match(
                r"CREATE\s+(UNIQUE\s+)?INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s+ON\s+([a-z_]\w*)\.([a-z_]\w*)",
                head,
                re.I,
            )
            if match:
                table = tables.get((match.group(3).lower(), match.group(4).lower()))
                if table is not None:
                    if match.group(1):
                        table.unique_names.add(match.group(2))
                    table.touch(migration)
            else:
                fail(path, f"cannot parse CREATE INDEX statement: {head[:80]}")
            kinds.append("index")
            continue
        if upper.startswith("CREATE TRIGGER"):
            match = re.match(
                r"CREATE\s+TRIGGER\s+(\w+)[\s\S]*?\bON\s+([a-z_]\w*)\.([a-z_]\w*)",
                head,
                re.I,
            )
            if not match:
                fail(path, "cannot parse CREATE TRIGGER statement")
            table = tables.get((match.group(2).lower(), match.group(3).lower()))
            if table is not None:
                table.triggers.add(match.group(1))
                table.touch(migration)
            kinds.append("trigger")
            continue
        if upper.startswith("DROP TRIGGER"):
            match = re.match(
                r"DROP\s+TRIGGER\s+(?:IF\s+EXISTS\s+)?(\w+)\s+ON\s+([a-z_]\w*)\.([a-z_]\w*)",
                head,
                re.I,
            )
            if match:
                table = tables.get((match.group(2).lower(), match.group(3).lower()))
                if table is not None:
                    table.triggers.discard(match.group(1))
                    table.touch(migration)
            kinds.append("drop trigger")
            continue
        if upper.startswith(("COMMENT ON", "COMMENT ")):
            kinds.append("comment")
            continue
        if upper.startswith("INSERT INTO"):
            kinds.append("insert")
        elif upper.startswith(("CREATE FUNCTION", "CREATE OR REPLACE FUNCTION")):
            kinds.append("function")
        elif upper.startswith("DO "):
            kinds.append("do block")
        elif upper.startswith("CREATE SEQUENCE"):
            kinds.append("sequence")
        elif upper.startswith("CREATE TYPE"):
            kinds.append("type")
        elif upper.startswith(("GRANT", "REVOKE", "ALTER DEFAULT PRIVILEGES")):
            kinds.append("privilege")
        elif upper.startswith("DROP "):
            kinds.append("drop")
        else:
            kinds.append("other")
    return found_tables, kinds


def load_contracts(root):
    path = root / "ops/migrations/contract-auto.txt"
    if not path.exists():
        fail(path, "missing contract migration list")
    entries = []
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not re.fullmatch(r"[a-z_]+/\d+_[a-z0-9_]+", stripped):
            fail(path, f"line {lineno}: cannot parse contract id '{stripped}'")
        module, stem = stripped.split("/", 1)
        migration = root / "modules" / module / "migrations" / f"{stem}.sql"
        if not migration.exists():
            fail(path, f"line {lineno}: {stripped} has no migration file")
        entries.append({"id": stripped, "file": f"{stem}.sql", "path": migration})
    return entries


def load_schema(root):
    def order(path):
        match = re.match(r"(\d+)_", path.name)
        seq = int(match.group(1)) if match else 10**9
        return (seq, path.parent.parent.name, path.name)

    migration_paths = sorted(root.glob("modules/*/migrations/*.sql"), key=order)
    if not migration_paths:
        fail(root / "modules", "no migration files found")
    tables = {}
    without_tables = []
    schemas = set()
    for path in migration_paths:
        found, kinds = parse_migration(path, root, tables)
        clean = _blank_comments(path.read_text(encoding="utf-8"))
        for match in re.finditer(
            r"CREATE\s+SCHEMA\s+(?:IF\s+NOT\s+EXISTS\s+)?([a-z_]\w*)", clean, re.I
        ):
            schemas.add(match.group(1).lower())
        summary = {}
        for kind in kinds:
            summary[kind] = summary.get(kind, 0) + 1
        if found == 0:
            without_tables.append({"migration": path.name, "summary": summary})
    contracts = load_contracts(root)
    contract_files = {entry["file"] for entry in contracts}
    for table in tables.values():
        if table.latest in contract_files:
            table.contract = True
    return tables, migration_paths, without_tables, contracts, schemas


def render_schema(root, tables, migration_paths, without_tables, contracts, schemas_declared):
    ordered = sorted(tables.values(), key=lambda t: (t.schema, t.name))
    schemas = {schema: 0 for schema in schemas_declared}
    for table in ordered:
        schemas[table.schema] = schemas.get(table.schema, 0) + 1
    created_files = len(migration_paths) - len(without_tables)
    marked = sum(1 for t in ordered if t.purpose)

    lines = [
        "<!-- GENERATED FILE: do not edit by hand. -->",
        "<!-- Source: modules/*/migrations/*.sql + ops/migrations/contract-auto.txt -->",
        "<!-- Regenerate: python3 tools/docsgen/docsgen.py schema -->",
        "<!-- Drift check: python3 tools/docsgen/docsgen.py schema --check -->",
        "",
        "# Schema inventory",
        "",
        "Every module owns one PostgreSQL schema and evolves it through numbered migrations",
        "(expand-only; contract migrations are separate). This page reflects **all migration",
        "files in the repository**, including contract migrations that deploy runs only when",
        "listed in `ops/migrations/contract-auto.txt`.",
        "",
        f"- Schemas: **{len(schemas)}**; tables: **{len(ordered)}**.",
        f"- Migration files: **{len(migration_paths)}** "
        f"({created_files} create at least one table, {len(without_tables)} do not).",
        f"- Tables with a `COMMENT ON TABLE` purpose: **{marked}** of {len(ordered)}.",
        f"- Contract migrations declared for automatic deploy: **{len(contracts)}**.",
        "",
        "Counts are worst-case declarations after replaying every migration in filename order.",
        "`unique` also counts `CREATE UNIQUE INDEX`, because both enforce uniqueness.",
        "`-` means the source states nothing; it is never a guess.",
        "",
        "## Tables",
        "",
        "| Schema | Table | Purpose | Key columns | PK/FK/UQ/CK | Invariant triggers | Latest migration |",
        "|---|---|---|---|---|---|---|",
    ]
    for table in ordered:
        pk = table.pk_columns()
        fk = table.fk_columns()
        key_parts = []
        if pk:
            key_parts.append("pk: " + ", ".join(pk))
        for columns, reference in fk:
            key_parts.append(
                "fk: " + ", ".join(columns) + " → " + (reference or "?")
            )
        pk_count, fk_count, uq_count, ck_count = table.counts()
        latest = table.latest or "-"
        if table.contract:
            latest += " (contract, auto)"
        lines.append(
            "| "
            + " | ".join(
                [
                    table.schema,
                    f"`{table.name}`",
                    comment_summary(table.purpose) if table.purpose else "-",
                    "; ".join(key_parts) if key_parts else "-",
                    f"{pk_count}/{fk_count}/{uq_count}/{ck_count}",
                    ", ".join(f"`{t}`" for t in sorted(table.triggers)) or "-",
                    f"`{latest}`",
                ]
            )
            + " |"
        )
    lines.extend(
        ["", "## Schemas", "", "| Schema | Tables |", "|---|---|"]
    )
    for schema in sorted(schemas):
        lines.append(f"| {schema} | {schemas[schema]} |")

    lines.extend(
        [
            "",
            "## Contract migrations",
            "",
            "These files change or remove existing objects and are executed automatically by",
            "deploy only because they are listed in `ops/migrations/contract-auto.txt`.",
            "",
            "| Contract id | File | Tables touched |",
            "|---|---|---|",
        ]
    )
    for entry in contracts:
        touched = sorted(
            f"{t.schema}.{t.name}" for t in ordered if entry["file"] in t.files
        )
        lines.append(f"| `{entry['id']}` | `{entry['path'].relative_to(root).as_posix()}` | "
                     + (", ".join(f"`{name}`" for name in touched) or "-") + " |")

    lines.extend(
        [
            "",
            "## Migrations without table creation",
            "",
            "ALTER/COMMENT/trigger/grant-only migrations still change the schema above; they are",
            "listed here so no migration file disappears from the inventory. `DDL recorded`",
            "counts the statements by kind.",
            "",
            "| Migration | DDL recorded |",
            "|---|---|",
        ]
    )
    for entry in without_tables:
        summary = entry["summary"]
        rendered = ", ".join(f"{kind} ({summary[kind]})" for kind in sorted(summary)) or "-"
        lines.append(f"| `{entry['migration']}` | {rendered} |")
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_outputs(root, mode):
    outputs = {}
    stats = {}
    if mode in ("params", "all"):
        params = load_parameters(root)
        catalogue_count = cross_check_catalogue(root, params)
        outputs["docs/PARAMETERS.md"] = render_parameters(root, params, catalogue_count)
        stats["parameters"] = len(params)
    if mode in ("schema", "all"):
        tables, migration_paths, without_tables, contracts, schemas = load_schema(root)
        outputs["docs/SCHEMA.md"] = render_schema(
            root, tables, migration_paths, without_tables, contracts, schemas
        )
        stats["tables"] = len(tables)
        stats["migrations"] = len(migration_paths)
        stats["migrations without table creation"] = len(without_tables)
    # SQL comments in the repository still use typographic dashes; the living docs
    # do not. Normalise here so generated and hand-written prose match.
    outputs = {name: normalise_dashes(text) for name, text in outputs.items()}
    return outputs, stats


def normalise_dashes(text):
    return text.replace("\u2014", "-").replace("\u2013", "-")


def write_output(root, relative, content):
    target = (root / relative).resolve()
    docs_dir = (root / "docs").resolve()
    if docs_dir not in target.parents:
        raise SourceError(f"{relative}: refusing to write outside docs/")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Generate docs/PARAMETERS.md and docs/SCHEMA.md from the repository."
    )
    parser.add_argument("mode", nargs="?", choices=["params", "schema", "all"], default="all")
    parser.add_argument("--check", action="store_true", help="fail when the committed docs drifted")
    parser.add_argument("--root", default=str(REPO_ROOT), help="repository root")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    try:
        outputs, stats = build_outputs(root, args.mode)
        selected = {
            "params": ["docs/PARAMETERS.md"],
            "schema": ["docs/SCHEMA.md"],
            "all": ["docs/PARAMETERS.md", "docs/SCHEMA.md"],
        }[args.mode]
        summary = ", ".join(f"{value} {name}" for name, value in sorted(stats.items()))
        if args.check:
            drifted = []
            for relative in selected:
                target = root / relative
                expected = outputs[relative]
                if not target.exists():
                    drifted.append(relative)
                    print(f"docsgen: {relative}: missing", file=sys.stderr)
                    continue
                actual = target.read_text(encoding="utf-8")
                if actual != expected:
                    drifted.append(relative)
                    diff = list(
                        difflib.unified_diff(
                            actual.splitlines(),
                            expected.splitlines(),
                            fromfile=f"{relative} (committed)",
                            tofile=f"{relative} (generated)",
                            lineterm="",
                        )
                    )
                    print(f"docsgen: {relative}: drift", file=sys.stderr)
                    for line in diff[:80]:
                        print(line, file=sys.stderr)
            if drifted:
                print("docsgen: regenerate with python3 tools/docsgen/docsgen.py", file=sys.stderr)
                return 1
            print(f"docsgen: in sync ({summary})")
            return 0
        for relative in selected:
            write_output(root, relative, outputs[relative])
            print(f"docsgen: wrote {relative}")
        print(f"docsgen: {summary}")
        return 0
    except SourceError as exc:
        print(f"docsgen: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
