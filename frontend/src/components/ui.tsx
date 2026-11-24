import type { ReactNode } from "react";
import { fmtPct } from "../lib/format";

export function PageHeader({ title, description, actions }: { title: string; description?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
      <div>
        <h1 className="text-xl font-semibold tracking-tight text-ink">{title}</h1>
        {description && <p className="mt-1 max-w-3xl text-sm text-muted">{description}</p>}
      </div>
      {actions}
    </div>
  );
}

export function Card({ title, subtitle, actions, children, className = "", bodyClassName = "" }: {
  title?: ReactNode; subtitle?: ReactNode; actions?: ReactNode; children: ReactNode; className?: string; bodyClassName?: string;
}) {
  return (
    <section className={`rounded-lg border border-line bg-surface shadow-[0_1px_2px_rgba(15,30,54,0.04)] ${className}`}>
      {(title || actions) && (
        <header className="flex flex-wrap items-start justify-between gap-2 border-b border-line px-4 py-3">
          <div>
            {title && <h2 className="text-sm font-semibold text-ink">{title}</h2>}
            {subtitle && <p className="mt-0.5 text-xs text-muted">{subtitle}</p>}
          </div>
          {actions}
        </header>
      )}
      <div className={bodyClassName}>{children}</div>
    </section>
  );
}

export function Kpi({ label, value, hint, tone = "neutral" }: {
  label: string; value: ReactNode; hint?: ReactNode; tone?: "neutral" | "pos" | "neg" | "warn";
}) {
  const bar = { neutral: "bg-line-strong", pos: "bg-pos", neg: "bg-neg", warn: "bg-[#d98a00]" }[tone];
  return (
    <div className="relative overflow-hidden rounded-lg border border-line bg-surface px-4 py-3">
      <span className={`absolute inset-y-0 left-0 w-1 ${bar}`} aria-hidden />
      <p className="text-xs font-medium uppercase tracking-wide text-muted">{label}</p>
      <p className="mt-1 text-2xl font-semibold tabular-nums text-ink">{value}</p>
      {hint && <p className="mt-0.5 text-xs text-muted">{hint}</p>}
    </div>
  );
}

type Tone = "pos" | "neg" | "warn" | "info" | "accent";
const toneClass: Record<Tone, string> = {
  pos: "bg-pos-soft text-pos border-pos/25",
  neg: "bg-neg-soft text-neg border-neg/25",
  warn: "bg-warn-soft text-warn border-warn/25",
  info: "bg-info-soft text-ink-2 border-line-strong",
  accent: "bg-accent-soft text-accent-strong border-accent/25",
};

export function Badge({ tone, icon, children }: { tone: Tone; icon?: string; children: ReactNode }) {
  return (
    <span className={`inline-flex items-center gap-1 whitespace-nowrap rounded border px-1.5 py-0.5 text-[11px] font-semibold ${toneClass[tone]}`}>
      {icon && <span aria-hidden>{icon}</span>}
      {children}
    </span>
  );
}

/** Severity: colour + icon + text label (never colour alone). */
export function SeverityBadge({ severity }: { severity: string }) {
  if (severity === "CRITICAL") return <Badge tone="neg" icon="✖">Critical</Badge>;
  if (severity === "WARNING") return <Badge tone="warn" icon="▲">Warning</Badge>;
  return <Badge tone="info" icon="ℹ">Info</Badge>;
}

export function IssueClassBadge({ issueClass }: { issueClass: string }) {
  return issueClass === "CONFIRMED_DEFECT"
    ? <Badge tone="neg" icon="●">Confirmed defect</Badge>
    : <Badge tone="accent" icon="◆">Review anomaly</Badge>;
}

export function StatusBadge({ status }: { status: string }) {
  const map: Record<string, [Tone, string, string]> = {
    OPEN: ["warn", "○", "Open"], UNDER_REVIEW: ["accent", "◐", "Under review"],
    RESOLVED: ["pos", "✓", "Resolved"], DISMISSED: ["info", "–", "Dismissed"],
    PASSED: ["pos", "✓", "Passed"], REVIEW: ["accent", "◆", "Review"], DEFECTS: ["neg", "✖", "Defects"],
    "NOT VALIDATED": ["neg", "✖", "Not validated"],
    SUCCEEDED: ["pos", "✓", "Succeeded"], PARTIAL: ["warn", "▲", "Partial"], FAILED: ["neg", "✖", "Failed"],
    SKIPPED: ["info", "↷", "Skipped (rerun)"], RUNNING: ["accent", "…", "Running"],
  };
  const [tone, icon, label] = map[status] ?? ["info", "", status];
  return <Badge tone={tone} icon={icon}>{label}</Badge>;
}

/** Signed change: green ▲ / red ▼ plus the signed number. */
export function Change({ value, digits = 2 }: { value: number | null | undefined; digits?: number }) {
  if (value === null || value === undefined) return <span className="text-muted">—</span>;
  const cls = value > 0 ? "text-pos" : value < 0 ? "text-neg" : "text-ink-2";
  const icon = value > 0 ? "▲" : value < 0 ? "▼" : "";
  return (
    <span className={`whitespace-nowrap font-medium tabular-nums ${cls}`}>
      <span aria-hidden className="mr-0.5 text-[10px]">{icon}</span>{fmtPct(value, digits, true)}
    </span>
  );
}

export function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="flex flex-col gap-1 text-xs font-medium text-ink-2">
      {label}
      {children}
    </label>
  );
}

export const inputClass =
  "h-8 rounded-md border border-line-strong bg-surface px-2 text-sm text-ink placeholder:text-muted focus:border-accent focus:outline-none";

export function Tabs<T extends string>({ value, onChange, options }: {
  value: T; onChange: (v: T) => void; options: { value: T; label: ReactNode }[];
}) {
  return (
    <div role="tablist" className="inline-flex rounded-md border border-line bg-canvas p-0.5">
      {options.map((o) => (
        <button key={o.value} role="tab" aria-selected={value === o.value} onClick={() => onChange(o.value)}
          className={`rounded px-3 py-1 text-xs font-medium ${value === o.value ? "bg-surface text-ink shadow-sm" : "text-muted hover:text-ink"}`}>
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function SyntheticBanner() {
  return (
    <div role="note" className="mb-4 flex items-start gap-2 rounded-md border border-warn/30 bg-warn-soft px-3 py-2 text-sm text-warn">
      <span aria-hidden className="font-bold">⚠</span>
      <span><strong>Synthetic test data.</strong> These results come from seeded fixtures in an isolated test database. They are not real market data and are never mixed with the real snapshot.</span>
    </div>
  );
}

/** Record outcome from audit.v_record_outcomes (records without failures are "clean"). */
export function OutcomeBadge({ outcome }: { outcome: string | null | undefined }) {
  switch (outcome) {
    case "QUARANTINED": return <Badge tone="neg" icon="✖">Quarantined</Badge>;
    case "ACCEPTED_WITH_FLAGS": return <Badge tone="accent" icon="◆">Promoted · flagged</Badge>;
    case "REDUNDANT_DUPLICATE": return <Badge tone="info" icon="⧉">Redundant copy</Badge>;
    case "HELD_FOR_REVIEW": return <Badge tone="warn" icon="⏸">Held for review</Badge>;
    default: return <Badge tone="pos" icon="✓">Clean</Badge>;
  }
}
