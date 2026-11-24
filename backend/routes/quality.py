"""Data Quality page: dimension scores, rules, issues, quarantine, synthetic tests."""
from __future__ import annotations

import json
from datetime import date

from fastapi import APIRouter, HTTPException, Path, Query
from typing import Annotated

from backend.database import PROJECT_ROOT, fetch_all, fetch_one
from backend.routes.common import (Category, IssueClass, IssueStatus, Limit, Offset, OptionalTicker, Severity,
                                   check_date_range, page)

router = APIRouter(prefix="/api/quality", tags=["data quality"])
SYNTHETIC_RESULTS = PROJECT_ROOT / "data" / "quality-tests" / "latest_results.json"


@router.get("/summary")
def summary() -> dict:
    return {
        "snapshot": fetch_one("SELECT * FROM analytics.v_dq_snapshot_summary"),
        "dimension_scores": fetch_all("SELECT * FROM analytics.v_dq_dimension_scores"),
        "field_completeness": fetch_all("SELECT * FROM analytics.v_dq_field_completeness ORDER BY field_name"),
        "issues_by_class_severity_status": fetch_all(
            "SELECT * FROM analytics.v_dq_issue_summary ORDER BY issue_class, severity, status"),
        # Loaded batches only: SKIPPED reruns carry no records (they stay visible in the
        # ingestion history as audit entries).
        "batches": fetch_all(
            """SELECT * FROM analytics.v_dq_batch_metrics
                WHERE status IN ('SUCCEEDED', 'PARTIAL')
                ORDER BY ingestion_batch_id DESC""", max_rows=50),
        "notes": {
            "scores": "numerator / denominator for the latest validated price batch; anomalies excluded",
            "records_vs_issues": "record counts and issue counts are reported separately",
        },
    }


@router.get("/rules")
def rules() -> dict:
    items = fetch_all("SELECT * FROM analytics.v_dq_rule_results ORDER BY rule_id")
    return page(items)


@router.get("/issues")
def issues(
    ticker: OptionalTicker = None,
    rule_id: Annotated[str | None, Query(pattern=r"^DQ-[A-Z]{3}-\d{3}$")] = None,
    severity: Severity | None = None,
    status: IssueStatus | None = None,
    issue_class: IssueClass | None = None,
    category: Category | None = None,
    date_from: date | None = None,
    date_to: date | None = None,
    limit: Limit = 100,
    offset: Offset = 0,
) -> dict:
    check_date_range(date_from, date_to)
    params = {"ticker": ticker, "rule_id": rule_id, "severity": severity, "status": status,
              "issue_class": issue_class, "category": category, "date_from": date_from,
              "date_to": date_to, "limit": limit, "offset": offset}
    # Fixed SQL; every filter is "parameter IS NULL OR column = parameter".
    where = """
        WHERE (%(ticker)s::text      IS NULL OR ticker = %(ticker)s)
          AND (%(rule_id)s::text     IS NULL OR rule_id = %(rule_id)s)
          AND (%(severity)s::text    IS NULL OR severity = %(severity)s)
          AND (%(status)s::text      IS NULL OR status = %(status)s)
          AND (%(issue_class)s::text IS NULL OR issue_class = %(issue_class)s)
          AND (%(category)s::text    IS NULL OR rule_category = %(category)s)
          AND (%(date_from)s::date   IS NULL OR trade_date >= %(date_from)s)
          AND (%(date_to)s::date     IS NULL OR trade_date <= %(date_to)s)"""
    total = fetch_one(f"SELECT count(*) AS n FROM analytics.v_dq_issues {where}", params)["n"]
    items = fetch_all(
        f"""SELECT issue_id, ticker, trade_date, rule_id, rule_name, rule_category, issue_class, affected_field,
                   observed_value, expected_condition, severity, status, handling, detected_at,
                   last_detected_at, detection_count, affected_records
              FROM analytics.v_dq_issues {where}
             ORDER BY CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END,
                      trade_date DESC NULLS LAST, issue_id
             LIMIT %(limit)s OFFSET %(offset)s""", params, max_rows=500)
    return page(items, limit, offset, total=total)


@router.get("/issues/{issue_id}")
def issue_detail(issue_id: Annotated[int, Path(ge=1, le=2**62)]) -> dict:
    issue = fetch_one("SELECT * FROM analytics.v_dq_issues WHERE issue_id = %(id)s", {"id": issue_id})
    if issue is None:
        raise HTTPException(status_code=404, detail=f"Issue {issue_id} not found")
    records = fetch_all(
        """SELECT f.failure_id, f.ingestion_batch_id, f.affected_field, f.observed_value, f.detected_at,
                  coalesce(f.raw_record_id, f.raw_action_id, f.raw_reference_id) AS raw_id,
                  CASE WHEN f.raw_record_id IS NOT NULL THEN 'PRICE'
                       WHEN f.raw_action_id IS NOT NULL THEN 'CORPORATE_ACTION' ELSE 'COMPANY_REFERENCE' END AS record_kind,
                  o.outcome, o.failed_rules
             FROM audit.rule_failures f
             LEFT JOIN audit.v_record_outcomes o
                    ON o.raw_id = coalesce(f.raw_record_id, f.raw_action_id, f.raw_reference_id)
                   AND o.record_kind = CASE WHEN f.raw_record_id IS NOT NULL THEN 'PRICE'
                                            WHEN f.raw_action_id IS NOT NULL THEN 'CORPORATE_ACTION'
                                            ELSE 'COMPANY_REFERENCE' END
            WHERE f.issue_id = %(id)s
            ORDER BY f.failure_id
            LIMIT 100""", {"id": issue_id})
    handling_text = {
        "QUARANTINE": "The affected record is not promoted to validated data; it stays in staging for investigation.",
        "ACCEPT_WITH_WARNING": "The business record is published; this warning is logged for follow-up.",
        "FLAG_FOR_REVIEW": "The record is published and flagged; an analyst decides whether it is genuine.",
    }
    return {"issue": issue, "proposed_handling": handling_text.get(issue["handling"]), "affected_records": records}


@router.get("/quarantine")
def quarantine(limit: Limit = 100, offset: Offset = 0) -> dict:
    items = fetch_all(
        """SELECT * FROM analytics.v_quarantined_records ORDER BY ingestion_batch_id, record_kind, raw_id
            LIMIT %(limit)s OFFSET %(offset)s""", {"limit": limit, "offset": offset}, max_rows=500)
    total = fetch_one("SELECT count(*) AS n FROM analytics.v_quarantined_records")["n"]
    return page(items, limit, offset, total=total)


@router.get("/synthetic-tests")
def synthetic_tests() -> dict:
    """Results of the isolated synthetic fixture tests (exported by scripts/run_quality_tests.sh).
    Clearly labelled SYNTHETIC: these are not real market data outcomes."""
    if not SYNTHETIC_RESULTS.exists():
        raise HTTPException(status_code=404, detail="No synthetic test results exported yet; run scripts/run_quality_tests.sh")
    data = json.loads(SYNTHETIC_RESULTS.read_text())
    return {"dataset": "SYNTHETIC", "warning": "Synthetic test fixtures only - not real market data.", **data}
