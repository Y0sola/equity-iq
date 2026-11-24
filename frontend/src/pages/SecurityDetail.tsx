import { useMemo, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { LineSeriesChart, VolumeChart } from "../components/charts";
import { DataTable } from "../components/DataTable";
import { Async } from "../components/States";
import { Card, Change, IssueClassBadge, PageHeader, SeverityBadge, StatusBadge, Tabs } from "../components/ui";
import { useApi } from "../hooks/useApi";
import { SERIES } from "../lib/colors";
import { fmtCompact, fmtDate, fmtNum, fmtPct, fmtPrice } from "../lib/format";
import type { CorporateAction, IssueRow, Page, PricePoint } from "../services/api";

type Range = "all" | "6m" | "3m";
interface Detail {
  overview: Record<string, unknown>; company: Record<string, unknown> | null;
  performance: Record<string, number | string | null> | null; volatility: Record<string, number | null> | null;
  volume: Record<string, number | null> | null;
}

export default function SecurityDetail() {
  const { ticker = "" } = useParams();
  const detail = useApi<Detail>(`/api/securities/${encodeURIComponent(ticker)}`);
  const prices = useApi<Page<PricePoint>>(`/api/securities/${encodeURIComponent(ticker)}/prices`);
  const actions = useApi<Page<CorporateAction>>(`/api/securities/${encodeURIComponent(ticker)}/corporate-actions`);
  const issues = useApi<Page<IssueRow>>(`/api/securities/${encodeURIComponent(ticker)}/issues`);
  const [range, setRange] = useState<Range>("all");

  const points = useMemo(() => {
    const all = prices.data?.items ?? [];
    if (range === "all" || all.length === 0) return all;
    const last = new Date(`${all[all.length - 1].trade_date}T00:00:00`);
    last.setMonth(last.getMonth() - (range === "6m" ? 6 : 3));
    return all.filter((p) => new Date(`${p.trade_date}T00:00:00`) >= last);
  }, [prices.data, range]);

  const company = detail.data?.company;
  return (
    <>
      <p className="mb-2 text-xs"><Link to="/securities" className="text-accent hover:underline">← Securities</Link></p>
      <PageHeader title={`${ticker}${company ? ` · ${company.company_name}` : ""}`}
        description={company ? `${company.sector} · ${company.industry ?? "—"} · ${company.exchange} · ${company.currency}` : undefined}
        actions={detail.data?.overview ? <StatusBadge status={String(detail.data.overview.quality_status)} /> : undefined} />
      <Async state={detail}>
        {(d) => !d.company ? (
          <Card><p className="px-4 py-6 text-sm text-ink-2">{ticker} is tracked but has no validated company record (its reference data did not pass validation). See its issues below.</p></Card>
        ) : (
          <div className="mb-5 grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6">
            <Stat label="Latest close" value={fmtPrice(d.overview.latest_close as number)} hint={fmtDate(d.overview.latest_trade_date as string)} />
            <Stat label="Adjusted return" value={<Change value={d.performance?.adjusted_return_pct as number} />} hint={`rank ${d.performance?.rank_overall} of 20`} />
            <Stat label="Price-only return" value={<Change value={d.performance?.price_return_pct as number} />} hint={`dividends $${fmtNum(d.performance?.dividends_per_share as number)}/share`} />
            <Stat label="Max drawdown" value={fmtPct(d.performance?.max_drawdown_pct as number)} hint="from running peak" />
            <Stat label="Volatility (ann.)" value={fmtPct(d.volatility?.annualised_volatility_pct, 1)} hint={`${d.volatility?.daily_returns_used} daily returns`} />
            <Stat label="Avg daily volume" value={fmtCompact(d.volume?.avg_daily_volume)} hint={`${d.volume?.unusual_volume_days} unusual-volume days`} />
          </div>
        )}
      </Async>

      <Card title="Price and moving averages" subtitle="Adjusted close with 20- and 50-session simple moving averages (adjusted basis). Volume is shown in a separate chart below."
        actions={<Tabs value={range} onChange={setRange} options={[{ value: "all", label: "Snapshot" }, { value: "6m", label: "6M" }, { value: "3m", label: "3M" }]} />}>
        <Async state={prices} empty={(d) => d.items.length === 0}>
          {() => (
            <div className="px-2 py-3">
              <LineSeriesChart height={300} yLabel="USD" ariaLabel={`${ticker} adjusted close and moving averages`} valueFormat={(v) => fmtNum(v, 2)}
                series={[
                  { key: "adj", label: "Adjusted close", color: SERIES[0], points: points.map((p) => ({ date: p.trade_date, value: p.adjusted_close })) },
                  { key: "sma20", label: "SMA 20", color: SERIES[1], points: points.map((p) => ({ date: p.trade_date, value: p.sma_20 })) },
                  { key: "sma50", label: "SMA 50", color: SERIES[2], dashed: true, points: points.map((p) => ({ date: p.trade_date, value: p.sma_50 })) },
                ]} />
              <p className="px-3 pb-1 pt-2 text-xs font-semibold text-ink-2">Volume <span className="font-normal text-muted">(dark bars: unusual, &gt; 3× trailing 20-record average)</span></p>
              <VolumeChart points={points.map((p) => ({ date: p.trade_date, volume: p.volume, unusual: p.is_unusual_volume }))} />
            </div>
          )}
        </Async>
      </Card>

      <div className="mt-5 grid gap-5 xl:grid-cols-2">
        <Card title="Corporate actions" subtitle="Ex-date basis. Reported vs adjusted return on the ex-date; descriptive only.">
          <Async state={actions}>
            {(d) => d.items.length === 0 ? <p className="px-4 py-6 text-sm text-muted">No dividends or splits in the snapshot window.</p> : (
              <DataTable caption="Corporate actions" rows={d.items} rowKey={(r) => r.action_id} columns={[
                { key: "d", header: "Ex-date", value: (r) => r.action_date, render: (r) => fmtDate(r.action_date) },
                { key: "t", header: "Type", value: (r) => r.action_type },
                { key: "a", header: "Amount / ratio", align: "right", render: (r) => r.action_type === "DIVIDEND" ? `$${fmtNum(r.dividend_amount, 4)}` : `${fmtNum(r.split_ratio, 4)} : 1` },
                { key: "y", header: "Yield", align: "right", render: (r) => fmtPct(r.dividend_yield_on_prev_close_pct, 3) },
                { key: "r", header: "Reported ret.", align: "right", render: (r) => <Change value={r.reported_return_pct} /> },
                { key: "j", header: "Adjusted ret.", align: "right", render: (r) => <Change value={r.adjusted_return_pct} /> },
              ]} />
            )}
          </Async>
        </Card>
        <Card title="Quality issues" subtitle="All issues recorded for this security"
          actions={<Link to={`/quality?tab=issues`} className="text-xs font-medium text-accent hover:underline">Issue register →</Link>}>
          <Async state={issues}>
            {(d) => d.items.length === 0 ? <p className="px-4 py-6 text-sm text-muted">No issues recorded for {ticker}.</p> : (
              <DataTable<IssueRow> caption="Issues" rows={d.items} rowKey={(r) => r.issue_id} maxHeight="22rem" columns={[
                { key: "d", header: "Date", value: (r) => r.trade_date, render: (r) => fmtDate(r.trade_date) },
                { key: "r", header: "Rule", render: (r) => <span><code className="text-[11px] text-muted">{r.rule_id}</code> {r.rule_name}</span> },
                { key: "o", header: "Observed", render: (r) => <span className="text-ink-2">{r.observed_value}</span> },
                { key: "c", header: "Class", render: (r) => <IssueClassBadge issueClass={r.issue_class} /> },
                { key: "s", header: "Severity", render: (r) => <SeverityBadge severity={r.severity} /> },
              ]} />
            )}
          </Async>
        </Card>
      </div>
    </>
  );
}

function Stat({ label, value, hint }: { label: string; value: React.ReactNode; hint?: string }) {
  return (
    <div className="rounded-lg border border-line bg-surface px-3 py-2.5">
      <p className="text-[11px] font-medium uppercase tracking-wide text-muted">{label}</p>
      <p className="mt-0.5 text-lg font-semibold tabular-nums">{value}</p>
      {hint && <p className="text-[11px] text-muted">{hint}</p>}
    </div>
  );
}
