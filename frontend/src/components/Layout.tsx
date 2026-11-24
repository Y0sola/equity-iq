import { NavLink, Outlet } from "react-router-dom";
import { useApi } from "../hooks/useApi";
import type { Overview } from "../services/api";
import { fmtDate } from "../lib/format";

const NAV = [
  { to: "/", label: "Overview", icon: "▦", group: "Core" },
  { to: "/quality", label: "Data Quality", icon: "✓", group: "Core" },
  { to: "/library", label: "SQL Library", icon: "⌘", group: "Core" },
  { to: "/securities", label: "Securities", icon: "≡", group: "Explore" },
  { to: "/corporate-actions", label: "Corporate Actions", icon: "◷", group: "Explore" },
  { to: "/ingestion", label: "Ingestion & Lineage", icon: "⇄", group: "Explore" },
];

export function Layout() {
  // Provenance shown on every page: source + fixed as-of window, straight from the API.
  const { data } = useApi<Overview>("/api/overview");
  const k = data?.kpis;
  return (
    <div className="flex h-full">
      <a href="#main" className="sr-only focus:not-sr-only focus:absolute focus:left-2 focus:top-2 focus:z-50 focus:rounded focus:bg-surface focus:px-3 focus:py-2">Skip to content</a>
      <aside className="flex w-56 shrink-0 flex-col bg-sidebar text-[#c9d3e3]">
        <div className="flex items-center gap-2 px-4 py-4">
          <span className="grid h-7 w-7 place-items-center rounded-md bg-[#1d3a66] text-sm font-bold text-[#9cc2ff]" aria-hidden>IQ</span>
          <div>
            <p className="text-sm font-semibold text-white">EquityIQ</p>
            <p className="text-[11px] text-[#8fa0ba]">Data management &amp; quality</p>
          </div>
        </div>
        <nav aria-label="Main" className="mt-2 flex-1 px-2">
          {["Core", "Explore"].map((group) => (
            <div key={group} className="mb-3">
              <p className="px-2 pb-1 text-[10px] font-semibold uppercase tracking-wider text-[#7f90ab]">{group}</p>
              {NAV.filter((n) => n.group === group).map((n) => (
                <NavLink key={n.to} to={n.to} end={n.to === "/"}
                  className={({ isActive }) => `mb-0.5 flex items-center gap-2.5 rounded-md px-2 py-1.5 text-[13px] font-medium ${isActive ? "bg-[#1d3a66] text-white" : "hover:bg-[#172b4b] hover:text-white"}`}>
                  <span aria-hidden className="w-4 text-center text-[#8fb4f0]">{n.icon}</span>{n.label}
                </NavLink>
              ))}
            </div>
          ))}
        </nav>
        <div className="border-t border-[#21365a] px-4 py-3 text-[11px] leading-relaxed text-[#8fa0ba]">
          Independent portfolio project. Historical data, not investment advice.
        </div>
      </aside>
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex flex-wrap items-center gap-x-4 gap-y-1 border-b border-line bg-surface px-6 py-2.5 text-xs text-ink-2">
          <span className="rounded bg-accent-soft px-1.5 py-0.5 font-semibold text-accent-strong">Historical snapshot</span>
          {k ? (
            <>
              <span><span className="text-muted">As of</span> <strong>{fmtDate(k.as_of_start_date)} – {fmtDate(k.as_of_end_date)}</strong></span>
              <span><span className="text-muted">Source</span> <strong>{k.source === "yahoo_finance" ? "Yahoo Finance (yfinance)" : k.source}</strong></span>
              <span><span className="text-muted">Snapshot</span> <code className="text-[11px]">{k.snapshot_label}</code></span>
            </>
          ) : <span className="text-muted">Loading snapshot metadata…</span>}
        </header>
        <main id="main" className="min-w-0 flex-1 overflow-y-auto px-6 py-5">
          <Outlet />
        </main>
      </div>
    </div>
  );
}
