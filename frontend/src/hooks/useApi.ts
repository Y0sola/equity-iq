import { useCallback, useEffect, useState } from "react";
import { apiGet } from "../services/api";

type Params = Record<string, string | number | undefined | null>;

/** Fetch a GET endpoint with loading / error / data states. Re-fetches when path or params change. */
export function useApi<T>(path: string | null, params?: Params) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState<boolean>(path !== null);
  const key = JSON.stringify(params ?? {});

  const load = useCallback(() => {
    if (path === null) return () => undefined;
    let cancelled = false;
    setLoading(true);
    setError(null);
    apiGet<T>(path, params)
      .then((d) => { if (!cancelled) setData(d); })
      .catch((e: Error) => { if (!cancelled) { setError(e.message); setData(null); } })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [path, key]);

  useEffect(() => load(), [load]);
  return { data, error, loading, reload: load };
}
