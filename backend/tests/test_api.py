"""EquityIQ API tests (synthetic fixture data in equityiq_test).

Expected values come from database/11_quality_test_data.sql: 6 requested tickers,
5 validated companies (MCD's reference data is quarantined), seeded defects.
"""
from __future__ import annotations

import time

import psycopg
import pytest

from backend import database
from backend.query_library import registry


# ------------------------------------------------------------------ system / security
def test_health_uses_read_only_role_on_test_db(client):
    r = client.get("/api/health")
    assert r.status_code == 200
    body = r.json()
    assert body["role"] == "equityiq_reader"
    assert body["read_only"] == "on"
    assert body["test_database"] is True and body["database"].endswith("_test")
    assert body["library_queries"] == 16


def test_reader_role_cannot_write():
    with pytest.raises(psycopg.Error) as exc:
        database.fetch_all("INSERT INTO ref.security_universe (ticker, assigned_sector) VALUES ('HACK', 'Energy')")
    assert isinstance(exc.value, (psycopg.errors.ReadOnlySqlTransaction, psycopg.errors.InsufficientPrivilege))


@pytest.mark.parametrize("method,path", [
    ("post", "/api/library/daily_returns/run"),
    ("put", "/api/quality/issues/1"),
    ("delete", "/api/quality/issues/1"),
    ("post", "/api/securities"),
])
def test_write_methods_not_allowed(client, method, path):
    assert getattr(client, method)(path).status_code == 405


def test_no_sql_text_endpoint(client):
    # Query-string SQL is ignored: the endpoint only runs the registered file.
    r = client.get("/api/library/database_overview/run", params={"sql": "DROP TABLE core.companies"})
    assert r.status_code == 200
    assert "row_count" in r.json()
    assert client.get("/api/library/run").status_code == 404


@pytest.mark.parametrize("bad", ["AAPL'; DROP TABLE core.companies;--", "aapl", "A" * 11, "1ABC"])
def test_ticker_injection_and_format_rejected(client, bad):
    assert client.get(f"/api/securities/{bad}").status_code in (404, 422)


def test_search_text_is_bound_not_executed(client):
    r = client.get("/api/securities", params={"search": "'; DROP TABLE core.companies; --"})
    assert r.status_code == 200 and r.json()["count"] == 0
    assert client.get("/api/securities/AAPL").status_code == 200   # table still there


def test_search_percent_is_not_a_wildcard(client):
    assert client.get("/api/securities", params={"search": "%"}).json()["count"] == 0


# ------------------------------------------------------------------ overview & performance
def test_overview(client):
    body = client.get("/api/overview").json()
    k = body["kpis"]
    assert k["tracked_securities"] == 20 and k["validated_companies"] == 5
    assert k["source"] == "synthetic_fixture"
    assert k["as_of_start_date"] == "2025-11-24" and k["as_of_end_date"] == "2026-02-27"
    scores = {d["dimension"]: d for d in client.get("/api/quality/summary").json()["dimension_scores"]}
    assert k["record_pass_rate_pct"] == scores["OVERALL"]["score_pct"]
    assert len(body["best_performers"]) == 5 and body["best_performers"][0]["rank_overall"] == 1
    assert {s["sector"] for s in body["sector_performance"]} == {
        "Information Technology", "Financials", "Energy", "Healthcare"}  # MCD's sector has no validated member
    assert len(body["recent_issues"]) == 8


def test_normalised_series(client):
    body = client.get("/api/performance/normalised", params={"tickers": "AAPL,MSFT"}).json()
    assert [s["ticker"] for s in body["series"]] == ["AAPL", "MSFT"]
    assert all(s["points"][0]["value"] == 100 for s in body["series"])
    assert body["base_date"] == "2025-11-24"


@pytest.mark.parametrize("tickers", ["aapl", ",".join(["AAPL"] * 21), "AAPL,DROP TABLE"])
def test_normalised_rejects_bad_ticker_lists(client, tickers):
    assert client.get("/api/performance/normalised", params={"tickers": tickers}).status_code == 422


def test_ranking_volatility_sectors(client):
    assert client.get("/api/performance/ranking").json()["count"] == 5
    vol = client.get("/api/volatility").json()["items"]
    assert all(v["annualised_volatility_pct"] is not None for v in vol)
    idx = client.get("/api/sectors/index", params={"sector": "Energy"}).json()
    assert idx["series"][0]["points"][0]["value"] == 100


# ------------------------------------------------------------------ data quality
def test_quality_summary_and_rules(client):
    s = client.get("/api/quality/summary").json()
    assert len(s["dimension_scores"]) == 7
    assert all("numerator" in d and "denominator" in d for d in s["dimension_scores"])
    assert client.get("/api/quality/rules").json()["count"] == 37


def test_issue_filters(client):
    crit = client.get("/api/quality/issues", params={"severity": "CRITICAL", "limit": 500}).json()
    assert crit["count"] > 0 and all(i["severity"] == "CRITICAL" for i in crit["items"])
    assert crit["total"] >= crit["count"]
    jpm = client.get("/api/quality/issues", params={"ticker": "JPM", "rule_id": "DQ-COM-004"}).json()
    assert [(i["ticker"], i["trade_date"]) for i in jpm["items"]] == [("JPM", "2026-01-13")]
    anomalies = client.get("/api/quality/issues", params={"issue_class": "REVIEWABLE_ANOMALY"}).json()
    assert all(i["issue_class"] == "REVIEWABLE_ANOMALY" for i in anomalies["items"])
    ranged = client.get("/api/quality/issues", params={"date_from": "2026-01-12", "date_to": "2026-01-12"}).json()
    assert ranged["count"] > 0 and all(i["trade_date"] == "2026-01-12" for i in ranged["items"])


def test_issue_pagination(client):
    p1 = client.get("/api/quality/issues", params={"limit": 5, "offset": 0}).json()["items"]
    p2 = client.get("/api/quality/issues", params={"limit": 5, "offset": 5}).json()["items"]
    assert len(p1) == 5 and not {i["issue_id"] for i in p1} & {i["issue_id"] for i in p2}


@pytest.mark.parametrize("params", [
    {"severity": "FATAL"}, {"status": "CLOSED"}, {"limit": 501}, {"limit": 0}, {"offset": -1},
    {"rule_id": "DQ-1"}, {"date_from": "2026-02-01", "date_to": "2026-01-01"}, {"date_from": "not-a-date"},
])
def test_issue_filter_validation(client, params):
    assert client.get("/api/quality/issues", params=params).status_code == 422


def test_issue_detail(client):
    issue_id = client.get("/api/quality/issues", params={"ticker": "JPM", "rule_id": "DQ-CNS-001"}).json()["items"][0]["issue_id"]
    body = client.get(f"/api/quality/issues/{issue_id}").json()
    assert body["issue"]["rule_description"] and body["issue"]["business_justification"]
    assert "not promoted" in body["proposed_handling"]
    assert body["affected_records"][0]["outcome"] == "QUARANTINED"
    assert client.get("/api/quality/issues/999999999").status_code == 404
    assert client.get("/api/quality/issues/abc").status_code == 422


def test_quarantine_matches_overview(client):
    q = client.get("/api/quality/quarantine", params={"limit": 500}).json()
    assert q["total"] == client.get("/api/overview").json()["kpis"]["quarantined_records"]


def test_synthetic_results_are_labelled(client):
    body = client.get("/api/quality/synthetic-tests").json()
    assert body["dataset"] == "SYNTHETIC" and "not real market data" in body["warning"]
    assert body["totals"]["failed"] == 0


# ------------------------------------------------------------------ securities & actions
def test_securities_list_includes_unvalidated(client):
    body = client.get("/api/securities").json()
    assert body["count"] == 20
    status = {s["ticker"]: s["quality_status"] for s in body["items"]}
    assert status["MCD"] == "NOT VALIDATED" and status["AAPL"] in ("PASSED", "REVIEW", "DEFECTS")
    assert [s["ticker"] for s in client.get("/api/securities", params={"search": "app"}).json()["items"]] == ["AAPL"]
    assert client.get("/api/securities", params={"sector": "Energy"}).json()["count"] == 4


def test_security_detail_and_prices(client):
    d = client.get("/api/securities/AAPL").json()
    assert d["company"]["company_name"] == "Fixture Apple" and d["performance"]["ticker"] == "AAPL"
    prices = client.get("/api/securities/AAPL/prices",
                        params={"date_from": "2026-01-05", "date_to": "2026-01-09"}).json()["items"]
    assert [p["trade_date"] for p in prices] == ["2026-01-05", "2026-01-06", "2026-01-08", "2026-01-09"]  # 01-07 quarantined
    assert client.get("/api/securities/ZZZZ").status_code == 404
    assert client.get("/api/securities/AAPL/prices", params={"date_from": "2026-02-01", "date_to": "2026-01-01"}).status_code == 422


def test_corporate_actions(client):
    assert client.get("/api/securities/JNJ/corporate-actions").json()["count"] == 1
    divs = client.get("/api/corporate-actions", params={"action_type": "DIVIDEND"}).json()["items"]
    assert {a["ticker"] for a in divs} == {"JNJ", "JPM"}
    assert client.get("/api/corporate-actions", params={"action_type": "MERGER"}).status_code == 422


# ------------------------------------------------------------------ ingestion & lineage
def test_ingestion_and_lineage(client):
    assert client.get("/api/ingestion/batches").json()["count"] == 3
    flow = client.get("/api/lineage/flow").json()
    assert flow["counts"]["validated_companies"] == 5 and len(flow["stages"]) == 6
    lin = client.get("/api/lineage/AAPL/2026-01-05").json()
    assert lin["raw_close"] is not None and lin["source"] == "synthetic_fixture"
    assert client.get("/api/lineage/AAPL/2026-01-07").status_code == 404   # quarantined: not in core


# ------------------------------------------------------------------ SQL library
def test_library_list(client):
    body = client.get("/api/library").json()
    assert body["count"] == 16
    assert {"Database", "Data quality", "Equity analysis", "Sector analysis", "Corporate actions", "Reporting"} <= set(body["categories"])


@pytest.mark.parametrize("query_id", sorted(registry()))
def test_every_library_query_runs(client, query_id):
    r = client.get(f"/api/library/{query_id}/run")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["row_count"] <= 500 and body["elapsed_ms"] >= 0
    assert len(body["columns"]) > 0


def test_library_detail_shows_view_definitions(client):
    body = client.get("/api/library/daily_returns").json()
    assert "LAG" in body["sql"] or "lag" in body["sql"].lower() or body["views_used"]
    assert body["views_used"] == ["analytics.v_daily_returns"]
    assert "lag(" in body["view_definitions"][0]["definition"].lower()


@pytest.mark.parametrize("bad", ["unknown_query", "DROP", "..%2F..%2Fetc%2Fpasswd", "a" * 65])
def test_library_unknown_or_unsafe_ids(client, bad):
    assert client.get(f"/api/library/{bad}/run").status_code in (404, 422)


# ------------------------------------------------------------------ error handling
def _raise(exc):
    def f(*a, **k):
        raise exc
    return f


def test_database_unavailable_returns_503(client, monkeypatch):
    monkeypatch.setattr(database, "get_reader_pool", _raise(psycopg.OperationalError("connection refused")))
    r = client.get("/api/overview")
    assert r.status_code == 503 and r.json()["error"] == "database_unavailable"


def test_timeout_returns_504(client, monkeypatch):
    monkeypatch.setattr(database, "get_reader_pool", _raise(psycopg.errors.QueryCanceled("canceling statement")))
    assert client.get("/api/volatility").status_code == 504


def test_errors_do_not_leak_sql(client, monkeypatch):
    monkeypatch.setattr(database, "get_reader_pool",
                        _raise(psycopg.errors.UndefinedTable('relation "secret" does not exist: SELECT * FROM secret')))
    r = client.get("/api/sectors")
    assert r.status_code == 500 and "SELECT" not in r.text and "secret" not in r.text


# ------------------------------------------------------------------ responsiveness (smoke)
@pytest.mark.parametrize("path", ["/api/overview", "/api/quality/summary", "/api/securities",
                                  "/api/securities/AAPL/prices", "/api/quality/issues"])
def test_endpoints_respond_quickly(client, path):
    started = time.perf_counter()
    assert client.get(path).status_code == 200
    assert time.perf_counter() - started < 2.0
