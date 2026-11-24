import { useState } from "react";

const KEYWORDS = new Set(("select from where and or not in is null as on join left right inner outer full cross lateral group by order having " +
  "limit offset with case when then else end distinct union all values asc desc nulls first last over partition rows range between " +
  "preceding following current row unbounded window filter within exists true false interval date using").split(" "));
const FUNCTIONS = new Set(("count sum avg min max round abs coalesce nullif lag lead rank row_number first_value stddev_samp sqrt " +
  "percentile_cont string_agg array_agg jsonb_agg date_trunc left concat_ws extract to_char").split(" "));

type Token = { text: string; cls?: string };

/** Minimal SQL tokenizer for display (comments, strings, numbers, keywords, functions). */
function tokenize(sql: string): Token[] {
  const re = /(--[^\n]*)|('(?:[^']|'')*')|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][A-Za-z0-9_]*)|(\s+|.)/g;
  const out: Token[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(sql))) {
    if (m[1]) out.push({ text: m[1], cls: "sql-comment" });
    else if (m[2]) out.push({ text: m[2], cls: "sql-string" });
    else if (m[3]) out.push({ text: m[3], cls: "sql-number" });
    else if (m[4]) {
      const w = m[4].toLowerCase();
      out.push({ text: m[4], cls: KEYWORDS.has(w) ? "sql-keyword" : FUNCTIONS.has(w) ? "sql-function" : undefined });
    } else out.push({ text: m[0] });
  }
  return out;
}

export function SqlCode({ sql, maxHeight = "28rem", label = "SQL" }: { sql: string; maxHeight?: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(sql);
    } catch {
      const ta = document.createElement("textarea");
      ta.value = sql; document.body.appendChild(ta); ta.select(); document.execCommand("copy"); ta.remove();
    }
    setCopied(true);
    setTimeout(() => setCopied(false), 1600);
  };
  return (
    <div className="relative rounded-md border border-line bg-[#fbfcfd]">
      <div className="flex items-center justify-between border-b border-line px-3 py-1.5">
        <span className="text-[11px] font-semibold uppercase tracking-wide text-muted">{label}</span>
        <button onClick={copy} className="rounded border border-line-strong bg-surface px-2 py-0.5 text-xs font-medium text-ink-2 hover:border-accent hover:text-accent"
          aria-label={`Copy ${label} to clipboard`}>
          {copied ? "✓ Copied" : "Copy"}
        </button>
      </div>
      <pre className="overflow-auto p-3 font-mono text-[12.5px] leading-relaxed text-ink" style={{ maxHeight }}>
        <code>{tokenize(sql).map((t, i) => t.cls ? <span key={i} className={t.cls}>{t.text}</span> : t.text)}</code>
      </pre>
    </div>
  );
}
