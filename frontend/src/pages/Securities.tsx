import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { DataTable } from "../components/DataTable";
import { Async } from "../components/States";
import { Card, Change, Field, PageHeader, StatusBadge, inputClass } from "../components/ui";
import { useApi } from "../hooks/useApi";
import { SECTOR_COLORS } from "../lib/colors";
import { fmtCompact, fmtDate, fmtPct, fmtPrice } from "../lib/format";
import type { Page, SecurityRow } from "../services/api";

export default function Securities() {
  const [search, setSearch] = useState("");
  const [sector, setSector] = useState("");
  const [status, setStatus] = useState("");
  const state = useApi<Page<SecurityRow>>("/api/securities", { search: search.trim() || undefined, sector, quality_status: status });
  const navigate = useNavigate();
  return (
    <>
      <PageHeader title="Securities" description="All tracked securities with validated metrics. Returns are adjusted-price performance over the snapshot window; volatility is annualised. Click a row for detail." />
      <Card>
        <div className="flex flex-wrap items-end gap-3 border-b border-line px-4 py-3">
          <Field label="Search ticker or company">
            <input className={`${inputClass} w-56`} value={search} maxLength={50} placeholder="e.g. NVDA or Apple" onChange={(e) => setSearch(e.target.value)} />
          </Field>
          <Field label="Sector">
            <select className={inputClass} value={sector} onChange={(e) => setSector(e.target.value)}>
              <option value="">All sectors</option>
              {Object.keys(SECTOR_COLORS).map((s) => <option key={s}>{s}</option>)}
            </select>
          </Field>
          <Field label="Quality status">
            <select className={inputClass} value={status} onChange={(e) => setStatus(e.target.value)}>
              <option value="">All</option><option value="PASSED">Passed</option><option value="REVIEW">Review</option>
              <option value="DEFECTS">Defects</option><option value="NOT VALIDATED">Not validated</option>
            </select>
          </Field>
          <p className="ml-auto text-xs text-muted">Review = open anomaly flags (published, unconfirmed); Defects = open confirmed defects.</p>
        </div>
        <Async state={state} empty={(d) => d.items.length === 0}>
          {(d) => (
            <DataTable<SecurityRow> caption="Securities" rows={d.items} rowKey={(r) => r.ticker} onRowClick={(r) => navigate(`/securities/${r.ticker}`)}
              initialSort={{ key: "ticker", dir: "asc" }} columns={[
                { key: "ticker", header: "Ticker", value: (r) => r.ticker, render: (r) => <span className="font-semibold text-accent">{r.ticker}</span> },
                { key: "co", header: "Company", value: (r) => r.company_name },
                { key: "sector", header: "Sector", value: (r) => r.sector, render: (r) => (
                  <span className="inline-flex items-center gap-1.5"><span className="h-2 w-2 rounded-sm" style={{ background: SECTOR_COLORS[r.sector] }} aria-hidden />{r.sector}</span>) },
                { key: "ex", header: "Exchange", value: (r) => r.exchange, className: "text-ink-2" },
                { key: "cur", header: "Ccy", value: (r) => r.currency, className: "text-ink-2" },
                { key: "close", header: "Latest close", align: "right", value: (r) => r.latest_close, render: (r) => fmtPrice(r.latest_close) },
                { key: "asof", header: "As of", value: (r) => r.latest_trade_date, render: (r) => <span className="text-muted">{fmtDate(r.latest_trade_date)}</span> },
                { key: "day", header: "Day", align: "right", value: (r) => r.latest_daily_return_pct, render: (r) => <Change value={r.latest_daily_return_pct} /> },
                { key: "period", header: "Period return", align: "right", value: (r) => r.period_adjusted_return_pct, render: (r) => <Change value={r.period_adjusted_return_pct} /> },
                { key: "vol", header: "Avg volume", align: "right", value: (r) => r.avg_daily_volume, render: (r) => fmtCompact(r.avg_daily_volume) },
                { key: "sd", header: "Volatility", align: "right", value: (r) => r.annualised_volatility_pct, render: (r) => fmtPct(r.annualised_volatility_pct, 1) },
                { key: "q", header: "Quality", value: (r) => r.quality_status, render: (r) => (
                  <span className="inline-flex items-center gap-1.5"><StatusBadge status={r.quality_status} />
                    {r.open_anomaly_issues + r.open_defect_issues > 0 && <span className="text-[11px] text-muted">{r.open_defect_issues + r.open_anomaly_issues} open</span>}</span>) },
              ]} />
          )}
        </Async>
      </Card>
    </>
  );
}
