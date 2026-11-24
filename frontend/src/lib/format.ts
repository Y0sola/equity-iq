// Formatting helpers. Units are always explicit; missing values render as an em dash (N/A).

const dash = "—";

export const fmtInt = (v: number | null | undefined) =>
  v === null || v === undefined ? dash : Math.round(v).toLocaleString("en-US");

export const fmtNum = (v: number | null | undefined, digits = 2) =>
  v === null || v === undefined ? dash : v.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });

export const fmtPct = (v: number | null | undefined, digits = 2, signed = false) =>
  v === null || v === undefined ? dash : `${signed && v > 0 ? "+" : ""}${fmtNum(v, digits)}%`;

export const fmtPrice = (v: number | null | undefined, currency = "USD") =>
  v === null || v === undefined ? dash : `${currency === "USD" ? "$" : ""}${fmtNum(v, 2)}`;

export const fmtCompact = (v: number | null | undefined) =>
  v === null || v === undefined ? dash : Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 }).format(v);

export const fmtDate = (v: string | null | undefined) => {
  if (!v) return dash;
  const d = new Date(v.length === 10 ? `${v}T00:00:00` : v);
  return d.toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric" });
};

export const fmtDateTime = (v: string | null | undefined) =>
  !v ? dash : new Date(v).toLocaleString("en-GB", { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", timeZoneName: "short" });

export const shortDate = (v: string) =>
  new Date(`${v}T00:00:00`).toLocaleDateString("en-GB", { month: "short", year: "2-digit" });

export const titleCase = (s: string) => s.toLowerCase().replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
