"""SQL Query Library registry: the allowlist of runnable queries.

Queries are the files in queries/*.sql (code, reviewed and versioned), never user
input. At start-up each file is parsed and checked:
  * file name is a safe identifier (becomes the query id),
  * required metadata header is present (title, category, objective, concepts),
  * it is a single SELECT/WITH statement with a LIMIT clause.
A file that fails any check is refused, not served.

The API can only execute a query by its id from this registry. There is no endpoint
that accepts SQL text.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from functools import lru_cache

from backend.database import PROJECT_ROOT

QUERY_DIR = PROJECT_ROOT / "queries"
ID_PATTERN = re.compile(r"^[a-z0-9_]{1,64}$")
REQUIRED = ("title", "category", "objective", "concepts")
VIEW_PATTERN = re.compile(r"\b(analytics|audit|staging|ref)\.(v_[a-z0-9_]+)\b")


@dataclass(frozen=True)
class LibraryQuery:
    query_id: str
    title: str
    category: str
    objective: str
    concepts: list[str]
    expected_output: str
    assumptions: str
    sql: str
    views_used: list[str] = field(default_factory=list)

    def summary(self) -> dict:
        return {
            "query_id": self.query_id, "title": self.title, "category": self.category,
            "objective": self.objective, "concepts": self.concepts,
        }

    def detail(self) -> dict:
        return {**self.summary(), "expected_output": self.expected_output, "assumptions": self.assumptions,
                "sql": self.sql, "views_used": self.views_used}


class LibraryError(ValueError):
    pass


def _parse(path) -> LibraryQuery:
    query_id = path.stem
    if not ID_PATTERN.match(query_id):
        raise LibraryError(f"{path.name}: unsafe file name")
    text = path.read_text()
    meta: dict[str, str] = {}
    for line in text.splitlines():
        m = re.match(r"^--\s*([a-z_]+):\s*(.+)$", line)
        if m:
            meta[m.group(1)] = m.group(2).strip()
        elif line.strip() and not line.startswith("--"):
            break
    missing = [k for k in REQUIRED if k not in meta]
    if missing:
        raise LibraryError(f"{path.name}: missing metadata {missing}")

    body = "\n".join(l for l in text.splitlines() if not l.strip().startswith("--")).strip()
    statement = body.rstrip().rstrip(";")
    if ";" in statement:
        raise LibraryError(f"{path.name}: more than one statement")
    if not re.match(r"^(SELECT|WITH)\b", statement, re.IGNORECASE):
        raise LibraryError(f"{path.name}: must be a SELECT or WITH query")
    if not re.search(r"\bLIMIT\s+\d+\s*$", statement, re.IGNORECASE):
        raise LibraryError(f"{path.name}: must end with a LIMIT clause")

    views = sorted({f"{s}.{v}" for s, v in VIEW_PATTERN.findall(statement)})
    return LibraryQuery(
        query_id=query_id, title=meta["title"], category=meta["category"], objective=meta["objective"],
        concepts=[c.strip() for c in meta["concepts"].split(",")],
        expected_output=meta.get("expected_output", ""), assumptions=meta.get("assumptions", ""),
        sql=text.strip(), views_used=views,
    )


@lru_cache(maxsize=1)
def registry() -> dict[str, LibraryQuery]:
    queries = {}
    for path in sorted(QUERY_DIR.glob("*.sql")):
        q = _parse(path)
        queries[q.query_id] = q
    return queries


def executable_sql(q: LibraryQuery) -> str:
    """The statement to execute: comments stripped, trailing semicolon removed."""
    body = "\n".join(l for l in q.sql.splitlines() if not l.strip().startswith("--"))
    return body.strip().rstrip(";")
