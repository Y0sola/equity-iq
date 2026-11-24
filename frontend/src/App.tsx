import { Suspense, lazy } from "react";
import { Route, Routes } from "react-router-dom";
import { Layout } from "./components/Layout";
import { EmptyState, Loading } from "./components/States";

// Each page is loaded on first visit, so e.g. the SQL Library never downloads the chart library.
const Overview = lazy(() => import("./pages/Overview"));
const DataQuality = lazy(() => import("./pages/DataQuality"));
const SqlLibrary = lazy(() => import("./pages/SqlLibrary"));
const Securities = lazy(() => import("./pages/Securities"));
const SecurityDetail = lazy(() => import("./pages/SecurityDetail"));
const CorporateActions = lazy(() => import("./pages/CorporateActions"));
const Ingestion = lazy(() => import("./pages/Ingestion"));

export default function App() {
  return (
    <Suspense fallback={<Loading label="Loading page…" />}>
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Overview />} />
        <Route path="quality" element={<DataQuality />} />
        <Route path="library" element={<SqlLibrary />} />
        <Route path="library/:queryId" element={<SqlLibrary />} />
        <Route path="securities" element={<Securities />} />
        <Route path="securities/:ticker" element={<SecurityDetail />} />
        <Route path="corporate-actions" element={<CorporateActions />} />
        <Route path="ingestion" element={<Ingestion />} />
        <Route path="*" element={<EmptyState title="Page not found" />} />
      </Route>
    </Routes>
    </Suspense>
  );
}
