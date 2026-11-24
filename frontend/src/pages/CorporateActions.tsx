import { useState } from "react";
import { Link } from "react-router-dom";
import { DataTable } from "../components/DataTable";
import { Async } from "../components/States";
import { Badge, Card, Change, Field, PageHeader, inputClass } from "../components/ui";
import { useApi } from "../hooks/useApi";
import { fmtDate, fmtNum, fmtPct, fmtPrice } from "../lib/format";
import type { CorporateAction, Page } from "../services/api";

export default function CorporateActions() {
  const [f, setF] = useState({ ticker: "", action_type: "", date_from: "", date_to: "" });
  const tickerValid = f.ticker === "" || /^[A-Z][A-Z.-]{0,9}$/.test(f.ticker);
  const state = useApi<Page<CorporateAction> & { interpretation: string }>(tickerValid ? "/api/corporate-actions" : null, { ...f, limit: 500 });
  const set = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
    setF((x) => ({ ...x, [k]: k === "ticker" ? e.target.value.toUpperCase() : e.target.value }));

  return (
    <>
      <PageHeader title="Corporate Actions"
        description="Validated dividends and stock splits. Amounts are per share on the ex-date, as reported by the provider." />
      <Card className="mb-5" title="How to read this">
        <ul className="list-disc space-y-1 py-3 pl-8 pr-4 text-sm text-ink-2">
          <li>On an <strong>ex-dividend date</strong> the reported close usually falls by roughly the dividend, because new buyers no longer receive it. The <strong>adjusted</strong> series removes that effect, so <em>reported − adjusted return ≈ −dividend yield</em>.</li>
          <li>Adjusted prices come from the provider (multiplicative adjustment, verified in SQL in Phase 2). Returns elsewhere in EquityIQ use adjusted close; reported prices are kept separately and never overwritten.</li>
          <li>No stock splits occurred in this snapshot, so split handling is demonstrated only with synthetic test fixtures. Price moves near action dates are shown descriptively; no cause is implied.</li>
        </ul>
      </Card>
      <Card>
        <div className="flex flex-wrap items-end gap-3 border-b border-line px-4 py-3">
          <Field label="Ticker"><input className={`${inputClass} w-24 ${tickerValid ? "" : "border-neg"}`} value={f.ticker} maxLength={10} onChange={set("ticker")} placeholder="e.g. JPM" aria-invalid={!tickerValid} /></Field>
          <Field label="Type">
            <select className={inputClass} value={f.action_type} onChange={set("action_type")}>
              <option value="">All</option><option value="DIVIDEND">Dividend</option><option value="STOCK_SPLIT">Stock split</option>
            </select>
          </Field>
          <Field label="From"><input type="date" className={inputClass} value={f.date_from} onChange={set("date_from")} /></Field>
          <Field label="To"><input type="date" className={inputClass} value={f.date_to} onChange={set("date_to")} /></Field>
          {state.data && <p className="ml-auto text-xs text-muted">{state.data.count} action{state.data.count === 1 ? "" : "s"}</p>}
        </div>
        <Async state={state} empty={(d) => d.items.length === 0}>
          {(d) => (
            <DataTable<CorporateAction> caption="Corporate actions" rows={d.items} rowKey={(r) => r.action_id} maxHeight="65vh" columns={[
              { key: "d", header: "Ex-date", value: (r) => r.action_date, render: (r) => fmtDate(r.action_date) },
              { key: "t", header: "Ticker", value: (r) => r.ticker, render: (r) => <Link to={`/securities/${r.ticker}`} className="font-semibold text-accent hover:underline">{r.ticker}</Link> },
              { key: "c", header: "Company", value: (r) => r.company_name },
              { key: "ty", header: "Type", value: (r) => r.action_type, render: (r) => <Badge tone={r.action_type === "DIVIDEND" ? "info" : "accent"}>{r.action_type === "DIVIDEND" ? "Dividend" : "Split"}</Badge> },
              { key: "a", header: "Amount / ratio", align: "right", value: (r) => r.dividend_amount ?? r.split_ratio, render: (r) => r.action_type === "DIVIDEND" ? `$${fmtNum(r.dividend_amount, 4)}` : `${fmtNum(r.split_ratio, 4)} : 1` },
              { key: "pc", header: "Prev. close", align: "right", value: (r) => r.prev_close_price, render: (r) => fmtPrice(r.prev_close_price) },
              { key: "y", header: "Yield", align: "right", value: (r) => r.dividend_yield_on_prev_close_pct, render: (r) => fmtPct(r.dividend_yield_on_prev_close_pct, 3) },
              { key: "rr", header: "Reported ret.", align: "right", value: (r) => r.reported_return_pct, render: (r) => <Change value={r.reported_return_pct} digits={3} /> },
              { key: "ar", header: "Adjusted ret.", align: "right", value: (r) => r.adjusted_return_pct, render: (r) => <Change value={r.adjusted_return_pct} digits={3} /> },
              { key: "df", header: "Rep. − adj.", align: "right", value: (r) => r.reported_minus_adjusted_pct, render: (r) => fmtPct(r.reported_minus_adjusted_pct, 3, true) },
              { key: "m", header: "Max move ±2 sessions", align: "right", value: (r) => r.max_abs_adjusted_move_pm2_pct, render: (r) => (
                <span>{fmtPct(r.max_abs_adjusted_move_pm2_pct, 2)}{r.significant_move_nearby && <span className="ml-1"><Badge tone="warn" icon="▲">&gt;10%</Badge></span>}</span>) },
            ]} />
          )}
        </Async>
      </Card>
    </>
  );
}
