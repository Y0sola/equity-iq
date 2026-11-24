// Colour follows the ENTITY, never its rank: a sector keeps its colour on every chart,
// and filtering never repaints the survivors. Palette validated (light mode) with the
// dataviz palette checker; three slots are below 3:1 contrast, so every chart ships a
// legend and a table view (relief rule).
export const SECTOR_COLORS: Record<string, string> = {
  "Information Technology": "#2a78d6",
  "Financials": "#eb6834",
  "Healthcare": "#1baf7a",
  "Energy": "#eda100",
  "Consumer Discretionary": "#e87ba4",
};

export const SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4"];

/** Securities inside one sector: fixed slot by alphabetical ticker order within the sector. */
export function tickerColor(ticker: string, sectorTickers: string[]): string {
  const idx = [...sectorTickers].sort().indexOf(ticker);
  return SERIES[idx >= 0 ? idx % SERIES.length : 0];
}

export const CHART = {
  grid: "#e7eaef",
  axis: "#5c6879",
  text: "#34425a",
};
