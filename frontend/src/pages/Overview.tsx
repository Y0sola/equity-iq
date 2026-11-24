import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { LineSeriesChart, SignedBarChart } from "../components/charts";
import { DataTable } from "../components/DataTable";
import { Async } from "../components/States";
import { Card, Change, IssueClassBadge, Kpi, PageHeader, SeverityBadge, StatusBadge, Tabs } from "../components/ui";
import { useApi } from "../hooks/useApi";
import { SECTOR_COLORS, tickerColor } from "../lib/colors";
import { fmtDate, fmtDateTime, fmtInt, fmtNum, fmtPct } from "../lib/format";
import type { IssueRow, Overview as OverviewData, Performer, Series } from "../services/api";

const SECTORS = Object.keys(SECTOR_COLORS);

export default function Overview() {
  const state = useApi<OverviewData>("/api/overview");
  return (
    <>
      <PageHeader title="Overview"
        description="Validated equity data for 20 US-listed companies across five sectors. Every figure is computed by SQL views in PostgreSQL and served by the read-only API." />
      <Async state={state}>{(d) => <OverviewBody data={d} />}</Async>
    </>
  );
}

function OverviewBody({ data }: { data: OverviewData }) {
  const k = data.kpis;
  const navigate = useNavigate();
  return (
    <div className="space-y-5">
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Kpi label="Tracked securities" value={k.tracked_securities} hint={`${k.sectors} sectors · ${k.validated_companies} validated`} />
        <Kpi label="Market records" value={fmtInt(k.market_records)} hint="raw daily price records received" />
        <Kpi label="Validated records" value={fmtInt(k.validated_price_records)}
          hint={`${fmtPct(k.validated_coverage_pct)} of ${fmtInt(k.expected_price_records)} expected sessions`} tone="pos" />
        <Kpi label="Record pass rate" value={fmtPct(k.record_pass_rate_pct)} hint="records with no confirmed defect ÷ records received"
          tone={k.record_pass_rate_pct === 100 ? "pos" : "warn"} />
        <Kpi label="Open confirmed defects" value={fmtInt(k.open_confirmed_defect_issues)} hint="issues; data proven wrong"
          tone={k.open_confirmed_defect_issues > 0 ? "neg" : "pos"} />
        <Kpi label="Anomalies for review" value={fmtInt(k.open_anomaly_issues)} hint="issues; published, flagged, possibly genuine"
          tone={k.open_anomaly_issues > 0 ? "warn" : "pos"} />
        <Kpi label="Quarantined records" value={fmtInt(k.quarantined_records)} hint="not promoted to validated data"
          tone={k.quarantined_records > 0 ? "neg" : "pos"} />
        <Kpi label="Last ingestion" value={<span className="text-base">{fmtDateTime(k.last_ingestion)}</span>}
          hint={`${fmtInt(k.validated_corporate_actions)} corporate actions validated`} />
      </div>

      <NormalisedCard />

      <div className="grid gap-5 xl:grid-cols-2">
        <Card title="Sector performance" subtitle="Equal-weight adjusted-price return of the four selected companies per sector (not official sector indices)">
          <div className="px-2 py-3">
            <SignedBarChart ariaLabel="Equal-weight sector returns"
              rows={data.sector_performance.map((s) => ({ label: s.sector, value: s.equal_weight_return_pct, color: SECTOR_COLORS[s.sector] ?? "#8793a5" }))} />
          </div>
          <DataTable caption="Sector performance" rowKey={(r) => r.sector} rows={data.sector_performance} columns={[
            { key: "rank", header: "#", value: (r) => r.rank_return, align: "right" },
            { key: "sector", header: "Sector", value: (r) => r.sector, render: (r) => (
              <span className="inline-flex items-center gap-2"><span className="h-2.5 w-2.5 rounded-sm" style={{ background: SECTOR_COLORS[r.sector] }} aria-hidden />{r.sector}</span>) },
            { key: "ret", header: "Return", value: (r) => r.equal_weight_return_pct, align: "right", render: (r) => <Change value={r.equal_weight_return_pct} /> },
            { key: "vol", header: "Index volatility (ann.)", value: (r) => r.sector_volatility_pct, align: "right", render: (r) => fmtPct(r.sector_volatility_pct) },
          ]} />
        </Card>
        <div className="grid gap-5 md:grid-cols-2 xl:grid-cols-1 2xl:grid-cols-2">
          <PerformerCard title="Best performers" rows={data.best_performers} />
          <PerformerCard title="Worst performers" rows={data.worst_performers} />
        </div>
      </div>

      <Card title="Recent validation issues" subtitle="Most recently detected data quality issues"
        actions={<Link to="/quality?tab=issues" className="text-xs font-medium text-accent hover:underline">View all issues →</Link>}>
        <DataTable<IssueRow> caption="Recent issues" rows={data.recent_issues} rowKey={(r) => r.issue_id}
          onRowClick={(r) => navigate(`/quality?tab=issues&issue=${r.issue_id}`)} columns={[
            { key: "ticker", header: "Ticker", value: (r) => r.ticker, render: (r) => <span className="font-semibold">{r.ticker ?? "—"}</span> },
            { key: "date", header: "Date", value: (r) => r.trade_date, render: (r) => fmtDate(r.trade_date) },
            { key: "rule", header: "Rule", render: (r) => <span><code className="text-[11px] text-muted">{r.rule_id}</code> {r.rule_name}</span> },
            { key: "class", header: "Class", render: (r) => <IssueClassBadge issueClass={r.issue_class} /> },
            { key: "sev", header: "Severity", render: (r) => <SeverityBadge severity={r.severity} /> },
            { key: "obs", header: "Observed", render: (r) => <span className="text-ink-2">{r.observed_value}</span> },
            { key: "status", header: "Status", render: (r) => <StatusBadge status={r.status} /> },
          ]} />
      </Card>
    </div>
  );
}

function PerformerCard({ title, rows }: { title: string; rows: Performer[] }) {
  return (
    <Card title={title} subtitle="Adjusted-price return over the snapshot window">
      <DataTable caption={title} rows={rows} rowKey={(r) => r.ticker} columns={[
        { key: "rank", header: "Rank", value: (r) => r.rank_overall, align: "right" },
        { key: "ticker", header: "Ticker", render: (r) => <Link to={`/securities/${r.ticker}`} className="font-semibold text-accent hover:underline">{r.ticker}</Link> },
        { key: "sector", header: "Sector", value: (r) => r.sector, className: "text-ink-2" },
        { key: "adj", header: "Adjusted", align: "right", value: (r) => r.adjusted_return_pct, render: (r) => <Change value={r.adjusted_return_pct} /> },
        { key: "px", header: "Price only", align: "right", value: (r) => r.price_return_pct, render: (r) => <Change value={r.price_return_pct} /> },
      ]} />
    </Card>
  );
}

function NormalisedCard() {
  const [view, setView] = useState<string>("sectors");
  const [showTable, setShowTable] = useState(false);
  const sectorIdx = useApi<{ series: Series[] }>(view === "sectors" ? "/api/sectors/index" : null);
  const secs = useApi<{ series: Series[]; base_date: string }>(view !== "sectors" ? "/api/performance/normalised" : null, { sector: view });
  const state = view === "sectors" ? sectorIdx : secs;

  return (
    <Card title="Normalised performance (base 100)"
      subtitle="Adjusted close rebased to 100 on the first common date. Sector lines are equal-weight indices of the four selected companies."
      actions={
        <div className="flex flex-wrap items-center gap-2">
          <Tabs value={view} onChange={setView} options={[{ value: "sectors", label: "Sector indices" },
            ...SECTORS.map((s) => ({ value: s, label: s.replace("Information Technology", "IT").replace("Consumer Discretionary", "Cons. Disc.") }))]} />
          <button onClick={() => setShowTable((v) => !v)} className="rounded border border-line-strong px-2 py-1 text-xs font-medium text-ink-2 hover:border-accent hover:text-accent"
            aria-pressed={showTable}>{showTable ? "Hide table" : "Show table"}</button>
        </div>}>
      <Async state={state as typeof sectorIdx} empty={(d) => d.series.length === 0}>
        {(d) => {
          const tickers = d.series.map((s) => s.ticker ?? "");
          const lines = d.series.map((s) => ({
            key: s.ticker ?? s.sector ?? "",
            label: s.ticker ?? s.sector ?? "",
            color: view === "sectors" ? SECTOR_COLORS[s.sector ?? ""] : tickerColor(s.ticker ?? "", tickers),
            points: s.points,
          }));
          return (
            <div className="px-2 py-3">
              <LineSeriesChart series={lines} yLabel="Index (base 100)" reference={100} height={320}
                ariaLabel="Normalised performance chart" valueFormat={(v) => fmtNum(v, 1)} />
              {showTable && (
                <DataTable caption="Normalised values" rowKey={(r) => r.key} rows={lines.map((l) => ({
                  key: l.key, color: l.color, first: l.points[0], last: l.points[l.points.length - 1],
                  max: Math.max(...l.points.map((p) => p.value)), min: Math.min(...l.points.map((p) => p.value)) }))}
                  columns={[
                    { key: "s", header: "Series", value: (r) => r.key, render: (r) => <span className="inline-flex items-center gap-2"><span className="h-0.5 w-4" style={{ background: r.color }} aria-hidden />{r.key}</span> },
                    { key: "fd", header: "Start", render: (r) => `${fmtDate(r.first?.date)} = ${fmtNum(r.first?.value, 1)}` },
                    { key: "lv", header: "End value", align: "right", value: (r) => r.last?.value, render: (r) => fmtNum(r.last?.value, 2) },
                    { key: "ch", header: "Change", align: "right", value: (r) => r.last?.value, render: (r) => <Change value={(r.last?.value ?? 100) - 100} /> },
                    { key: "hi", header: "High", align: "right", value: (r) => r.max, render: (r) => fmtNum(r.max, 1) },
                    { key: "lo", header: "Low", align: "right", value: (r) => r.min, render: (r) => fmtNum(r.min, 1) },
                  ]} />
              )}
            </div>
          );
        }}
      </Async>
    </Card>
  );
}
