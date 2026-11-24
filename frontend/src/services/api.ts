// Typed client for the read-only EquityIQ API. Every number on the dashboard comes from here.

export class ApiError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

export async function apiGet<T>(path: string, params?: Record<string, string | number | undefined | null>): Promise<T> {
  const query = new URLSearchParams();
  Object.entries(params ?? {}).forEach(([k, v]) => {
    if (v !== undefined && v !== null && v !== "") query.set(k, String(v));
  });
  const url = query.toString() ? `${path}?${query}` : path;
  let res: Response;
  try {
    res = await fetch(url, { headers: { Accept: "application/json" } });
  } catch {
    throw new ApiError(0, "The API is not reachable. Is the backend running on port 8000?");
  }
  if (!res.ok) {
    let message = `Request failed (${res.status})`;
    try {
      const body = await res.json();
      if (typeof body.detail === "string") message = body.detail;
      else if (Array.isArray(body.detail)) message = body.detail.map((d: { msg: string }) => d.msg).join("; ");
      else if (body.error) message = `${body.error}: ${body.detail ?? ""}`;
    } catch { /* keep default */ }
    throw new ApiError(res.status, message);
  }
  return res.json() as Promise<T>;
}

// ------------------------------------------------------------------ response types
export interface Page<T> { count: number; limit?: number | null; offset?: number; total?: number; items: T[]; [k: string]: unknown }

export interface Kpis {
  tracked_securities: number; sectors: number; validated_companies: number; market_records: number;
  validated_price_records: number; expected_price_records: number; validated_coverage_pct: number | null;
  record_pass_rate_pct: number | null; quarantined_records: number; open_confirmed_defect_issues: number;
  open_anomaly_issues: number; validated_corporate_actions: number; last_ingestion: string | null;
  as_of_start_date: string; as_of_end_date: string; snapshot_label: string; source: string;
}
export interface Performer { ticker: string; sector: string; adjusted_return_pct: number; price_return_pct: number; rank_overall: number }
export interface SectorPerf {
  sector: string; constituents: number; equal_weight_return_pct: number; sector_volatility_pct: number | null; rank_return: number;
  equal_weight_price_return_pct?: number; best_constituent?: string; worst_constituent?: string;
  best_constituent_return_pct?: number; worst_constituent_return_pct?: number; avg_constituent_volatility_pct?: number | null;
  avg_constituent_daily_volume?: number;
}
export interface IssueRow {
  issue_id: number; ticker: string | null; trade_date: string | null; rule_id: string; rule_name: string;
  rule_category?: string; issue_class: "CONFIRMED_DEFECT" | "REVIEWABLE_ANOMALY"; affected_field?: string;
  observed_value: string | null; expected_condition?: string | null; severity: "CRITICAL" | "WARNING" | "INFO";
  status: string; handling?: string; detected_at: string; last_detected_at?: string; detection_count?: number; affected_records?: number;
}
export interface Overview { kpis: Kpis; best_performers: Performer[]; worst_performers: Performer[]; sector_performance: SectorPerf[]; recent_issues: IssueRow[] }
export interface SeriesPoint { date: string; value: number }
export interface Series { ticker?: string; sector?: string; points: SeriesPoint[] }
export interface DimensionScore { dimension: string; scope: string; numerator: number; denominator: number; score_pct: number | null; definition: string }
export interface QualitySummary {
  snapshot: Record<string, unknown>;
  dimension_scores: DimensionScore[];
  field_completeness: { field_name: string; records_evaluated: number; present: number; present_and_parseable: number; completeness_pct: number | null }[];
  issues_by_class_severity_status: { issue_class: string; severity: string; status: string; issues: number; tickers_affected: number }[];
  batches: Record<string, unknown>[];
}
export interface RuleResult {
  rule_id: string; rule_name: string; rule_category: string; severity: string; issue_class: string; handling: string;
  threshold_value: number | null; rule_description: string; expected_condition: string; business_justification: string;
  failing_records: number; issues_total: number; issues_unresolved: number;
}
export interface LibrarySummary { query_id: string; title: string; category: string; objective: string; concepts: string[] }
export interface LibraryDetail extends LibrarySummary {
  expected_output: string; assumptions: string; sql: string; views_used: string[];
  view_definitions: { view: string; definition: string }[];
}
export interface LibraryRun { query_id: string; title: string; columns: string[]; rows: Record<string, unknown>[]; row_count: number; truncated: boolean; elapsed_ms: number }
export interface SecurityRow {
  ticker: string; company_name: string | null; sector: string; industry: string | null; exchange: string | null; currency: string | null;
  latest_trade_date: string | null; latest_close: number | null; latest_daily_return_pct: number | null;
  period_adjusted_return_pct: number | null; period_price_return_pct: number | null; avg_daily_volume: number | null;
  annualised_volatility_pct: number | null; open_defect_issues: number; open_anomaly_issues: number; quarantined_records: number;
  quality_status: "PASSED" | "REVIEW" | "DEFECTS" | "NOT VALIDATED";
}
export interface PricePoint {
  trade_date: string; open_price: number; high_price: number; low_price: number; close_price: number; adjusted_close: number;
  volume: number; daily_return_pct: number | null; return_type: string; sma_20: number | null; sma_50: number | null;
  volume_ratio: number | null; is_unusual_volume: boolean;
}
export interface CorporateAction {
  action_id: number; ticker: string; company_name?: string; sector: string; action_date: string; action_type: string;
  dividend_amount: number | null; split_ratio: number | null; prev_close_price: number | null; ex_date_close: number | null;
  reported_return_pct: number | null; adjusted_return_pct: number | null; reported_minus_adjusted_pct: number | null;
  dividend_yield_on_prev_close_pct: number | null; max_abs_adjusted_move_pm2_pct: number | null; significant_move_nearby: boolean;
}
