import {
  Bar, BarChart, CartesianGrid, Cell, LabelList, Legend, Line, LineChart, ReferenceLine,
  ResponsiveContainer, Tooltip, XAxis, YAxis,
} from "recharts";
import { CHART } from "../lib/colors";
import { fmtDate, fmtNum, fmtPct, shortDate } from "../lib/format";

export interface LineSeries { key: string; label: string; color: string; points: { date: string; value: number | null }[]; dashed?: boolean }

/** One axis tick per calendar month (first trading date seen in each month). */
function monthTicks(dates: string[]): string[] {
  const seen = new Set<string>();
  return dates.filter((d) => {
    const m = d.slice(0, 7);
    if (seen.has(m)) return false;
    seen.add(m);
    return true;
  });
}

/** Pivot series into one row per date for Recharts. */
function pivot(series: LineSeries[]) {
  const rows = new Map<string, Record<string, number | string | null>>();
  series.forEach((s) => s.points.forEach((p) => {
    const row = rows.get(p.date) ?? { date: p.date };
    row[s.key] = p.value;
    rows.set(p.date, row);
  }));
  return [...rows.values()].sort((a, b) => String(a.date).localeCompare(String(b.date)));
}

/** Multi-series line chart: one y-axis only, legend always shown for >= 2 series,
 *  crosshair tooltip, recessive grid. */
export function LineSeriesChart({ series, height = 300, yLabel, reference, valueFormat = (v) => fmtNum(v, 2), ariaLabel }: {
  series: LineSeries[]; height?: number; yLabel: string; reference?: number;
  valueFormat?: (v: number) => string; ariaLabel: string;
}) {
  const data = pivot(series);
  return (
    <div role="img" aria-label={ariaLabel} style={{ height }}>
      <ResponsiveContainer width="100%" height="100%">
        <LineChart data={data} margin={{ top: 8, right: 16, bottom: 4, left: 8 }}>
          <CartesianGrid stroke={CHART.grid} vertical={false} />
          <XAxis dataKey="date" tickFormatter={shortDate} ticks={monthTicks(data.map((d) => String(d.date)))} minTickGap={24}
            tick={{ fill: CHART.axis, fontSize: 11 }} axisLine={{ stroke: CHART.grid }} tickLine={false} />
          <YAxis tick={{ fill: CHART.axis, fontSize: 11 }} axisLine={false} tickLine={false} width={56}
            domain={["auto", "auto"]} tickFormatter={(v: number) => valueFormat(v)}
            label={{ value: yLabel, angle: -90, position: "insideLeft", fill: CHART.axis, fontSize: 11, dy: 40 }} />
          {reference !== undefined && <ReferenceLine y={reference} stroke="#9aa5b5" strokeDasharray="4 3" />}
          <Tooltip
            labelFormatter={(d) => fmtDate(String(d))}
            formatter={(v, name) => [typeof v === "number" ? valueFormat(v) : "—", series.find((s) => s.key === name)?.label ?? name]}
            contentStyle={{ fontSize: 12, borderRadius: 6, borderColor: "#c9d0da" }}
            itemSorter={(item) => -(Number(item.value) || 0)}
          />
          {series.length >= 2 && (
            <Legend formatter={(key) => <span style={{ color: CHART.text, fontSize: 12 }}>{series.find((s) => s.key === key)?.label ?? key}</span>} iconType="plainline" />
          )}
          {series.map((s) => (
            <Line key={s.key} type="monotone" dataKey={s.key} stroke={s.color} strokeWidth={2} dot={false}
              strokeDasharray={s.dashed ? "5 4" : undefined} connectNulls={false} isAnimationActive={false}
              activeDot={{ r: 4, strokeWidth: 2, stroke: "#fff" }} />
          ))}
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}

/** Horizontal bars for signed percentages (e.g. sector returns), zero baseline, direct value labels. */
export function SignedBarChart({ rows, height, ariaLabel }: {
  rows: { label: string; value: number; color: string }[]; height?: number; ariaLabel: string;
}) {
  const h = height ?? 44 * rows.length + 30;
  return (
    <div role="img" aria-label={ariaLabel} style={{ height: h }}>
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={rows} layout="vertical" margin={{ top: 4, right: 56, bottom: 4, left: 8 }} barCategoryGap={10}>
          <CartesianGrid stroke={CHART.grid} horizontal={false} />
          <XAxis type="number" tickFormatter={(v: number) => `${v}%`} tick={{ fill: CHART.axis, fontSize: 11 }}
            axisLine={false} tickLine={false} domain={[(min: number) => Math.min(0, Math.floor(min / 20) * 20), (max: number) => Math.max(0, Math.ceil(max / 20) * 20)]} />
          <YAxis type="category" dataKey="label" width={150} tick={{ fill: CHART.text, fontSize: 12 }} axisLine={false} tickLine={false} />
          <ReferenceLine x={0} stroke="#8793a5" />
          <Tooltip formatter={(v) => [fmtPct(Number(v), 2, true), "Equal-weight return"]} cursor={{ fill: "#eef2f7" }}
            contentStyle={{ fontSize: 12, borderRadius: 6, borderColor: "#c9d0da" }} />
          <Bar dataKey="value" radius={4} isAnimationActive={false}>
            {rows.map((r) => <Cell key={r.label} fill={r.color} />)}
            <LabelList dataKey="value" position="right" formatter={(v) => fmtPct(Number(v), 1, true)}
              style={{ fill: CHART.text, fontSize: 11, fontWeight: 600 }} />
          </Bar>
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}

/** Volume bars (separate chart, never a second y-axis on the price chart). */
export function VolumeChart({ points, height = 140 }: { points: { date: string; volume: number; unusual: boolean }[]; height?: number }) {
  return (
    <div role="img" aria-label="Daily traded volume" style={{ height }}>
      <ResponsiveContainer width="100%" height="100%">
        <BarChart data={points} margin={{ top: 4, right: 16, bottom: 4, left: 8 }} barCategoryGap={1}>
          <CartesianGrid stroke={CHART.grid} vertical={false} />
          <XAxis dataKey="date" tickFormatter={shortDate} ticks={monthTicks(points.map((p) => p.date))} minTickGap={24}
            tick={{ fill: CHART.axis, fontSize: 11 }} axisLine={{ stroke: CHART.grid }} tickLine={false} />
          <YAxis tick={{ fill: CHART.axis, fontSize: 11 }} axisLine={false} tickLine={false} width={56}
            tickFormatter={(v: number) => Intl.NumberFormat("en-US", { notation: "compact" }).format(v)}
            label={{ value: "Shares", angle: -90, position: "insideLeft", fill: CHART.axis, fontSize: 11, dy: 20 }} />
          <Tooltip labelFormatter={(d) => fmtDate(String(d))}
            formatter={(v, _n, item) => [`${Number(v).toLocaleString("en-US")}${(item?.payload as { unusual?: boolean })?.unusual ? "  (unusual: >3× trailing avg)" : ""}`, "Volume"]}
            contentStyle={{ fontSize: 12, borderRadius: 6, borderColor: "#c9d0da" }} cursor={{ fill: "#eef2f7" }} />
          <Bar dataKey="volume" isAnimationActive={false}>
            {points.map((p) => <Cell key={p.date} fill={p.unusual ? "#154aa8" : "#9ec5f4"} />)}
          </Bar>
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}
