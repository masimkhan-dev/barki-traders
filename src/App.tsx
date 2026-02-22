import { Toaster } from "@/components/ui/toaster";
import { Toaster as Sonner } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { BrowserRouter, Routes, Route, Navigate } from "react-router-dom";
import { AuthProvider, useAuth } from "@/contexts/AuthContext";
import { lazy, Suspense } from "react";
import { ErrorBoundary } from "@/components/ErrorBoundary";

// Lazy-loaded pages — each becomes a separate JS chunk, loaded only when navigated to
const Auth = lazy(() => import("./pages/Auth"));
const Dashboard = lazy(() => import("./pages/Dashboard"));
const Roznamcha = lazy(() => import("./pages/Roznamcha"));
const Inventory = lazy(() => import("./pages/Inventory"));
const Ledger = lazy(() => import("./pages/Ledger"));
const ManageTransactions = lazy(() => import("./pages/ManageTransactions"));
const Users = lazy(() => import("./pages/Users"));
const Expenses = lazy(() => import("./pages/Expenses"));
const AccountStatement = lazy(() => import("./pages/AccountStatement"));
const TrialBalance = lazy(() => import("./pages/TrialBalance"));
const BalanceSheet = lazy(() => import("./pages/BalanceSheet"));
const ProfitLossReport = lazy(() => import("./pages/ProfitLossReport"));
const BusinessReports = lazy(() => import("./pages/BusinessReports"));
const SetupOpeningBalance = lazy(() => import("./pages/SetupOpeningBalance"));
const MonthEndClosing = lazy(() => import("./pages/MonthEndClosing"));
const CapitalReport = lazy(() => import("./pages/CapitalReport"));
const ResetPassword = lazy(() => import("./pages/ResetPassword"));
const NotFound = lazy(() => import("./pages/NotFound"));
const ChartOfAccounts = lazy(() => import("./pages/ChartOfAccounts"));
import { Loader2 } from "lucide-react";
import ScrollToTop from "./components/ScrollToTop";

// FIX: Infinite Retry Storm (Circuit Breaker)
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: (failureCount, error: any) => {
        if (error?.status === 404 || error?.status === 400) return false;
        return failureCount < 1;
      },
      refetchOnWindowFocus: true, // Auto-refresh when user comes back to the tab
      staleTime: 0, // ALWAYS consider data stale in a financial system
      gcTime: 1000 * 60 * 10, // Keep in memory for 10 mins
    },
  },
});

function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const { user, role, loading } = useAuth();

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  if (!user) {
    return <Navigate to="/auth" replace />;
  }

  if (!role) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <div className="text-center p-8">
          <h2 className="text-xl font-semibold mb-2">Awaiting Role Assignment</h2>
          <p className="text-muted-foreground">Please contact admin to assign your role.</p>
        </div>
      </div>
    );
  }

  return <>{children}</>;
}

function AppRoutes() {
  const { user, role, loading } = useAuth();

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-background">
        <Loader2 className="h-8 w-8 animate-spin text-primary" />
      </div>
    );
  }

  // Accountants land on Roznamcha, Admins on Dashboard
  const defaultRoute = role === 'accountant' ? '/roznamcha' : '/dashboard';

  return (
    <Suspense fallback={<div className="min-h-screen flex items-center justify-center bg-background"><Loader2 className="h-8 w-8 animate-spin text-primary" /></div>}>
      <Routes>
        <Route path="/auth" element={user && role ? <Navigate to={defaultRoute} replace /> : <Auth />} />
        <Route path="/reset-password" element={<ResetPassword />} />
        <Route path="/" element={<Navigate to={defaultRoute} replace />} />
        <Route path="/roznamcha" element={<ProtectedRoute><Roznamcha /></ProtectedRoute>} />
        <Route path="/dashboard" element={<ProtectedRoute><Dashboard /></ProtectedRoute>} />
        {/* Deprecated: <Route path="/customers" element={<ProtectedRoute><Customers /></ProtectedRoute>} /> */}
        {/* Deprecated: <Route path="/suppliers" element={<ProtectedRoute><Suppliers /></ProtectedRoute>} /> */}
        <Route path="/inventory" element={<ProtectedRoute><Inventory /></ProtectedRoute>} />
        {/* Deprecated: <Route path="/purchases" element={<ProtectedRoute><Purchases /></ProtectedRoute>} /> */}
        {/* Deprecated: <Route path="/sales" element={<ProtectedRoute><Sales /></ProtectedRoute>} /> */}
        <Route path="/ledger" element={<ProtectedRoute><Ledger /></ProtectedRoute>} />
        <Route path="/expenses" element={<ProtectedRoute><Expenses /></ProtectedRoute>} />
        <Route path="/reports" element={<Navigate to="/reports/account-statement" replace />} />
        {/* Deprecated: <Route path="/cash-transactions" element={<ProtectedRoute><CashTransactions /></ProtectedRoute>} /> */}
        <Route path="/manage-transactions" element={<ProtectedRoute><ManageTransactions /></ProtectedRoute>} />
        <Route path="/operations" element={<Navigate to={`/manage-transactions${window.location.search}`} replace />} />
        <Route path="/reports/account-statement" element={<ProtectedRoute><AccountStatement /></ProtectedRoute>} />
        <Route path="/reports/trial-balance" element={<ProtectedRoute><TrialBalance /></ProtectedRoute>} />
        <Route path="/reports/balance-sheet" element={<ProtectedRoute><BalanceSheet /></ProtectedRoute>} />
        <Route path="/reports/profit-loss" element={<ProtectedRoute><ProfitLossReport /></ProtectedRoute>} />
        <Route path="/reports/business" element={<ProtectedRoute><BusinessReports /></ProtectedRoute>} />
        <Route path="/setup-opening-balance" element={<ProtectedRoute><SetupOpeningBalance /></ProtectedRoute>} />
        <Route path="/month-end-closing" element={<ProtectedRoute><MonthEndClosing /></ProtectedRoute>} />
        <Route path="/reports/capital" element={<ProtectedRoute><CapitalReport /></ProtectedRoute>} />
        <Route path="/users" element={<ProtectedRoute><Users /></ProtectedRoute>} />
        <Route path="/settings/coa" element={<ProtectedRoute><ChartOfAccounts /></ProtectedRoute>} />
        <Route path="*" element={<NotFound />} />
      </Routes>
    </Suspense>
  );
}

const App = () => (
  <QueryClientProvider client={queryClient}>
    <TooltipProvider>
      <Toaster />
      <Sonner />
      {/* FIX: React Router v7 Future Flag */}
      <BrowserRouter future={{ v7_relativeSplatPath: true, v7_startTransition: true }}>
        <ScrollToTop />
        <AuthProvider>
          <ErrorBoundary>
            <AppRoutes />
          </ErrorBoundary>
        </AuthProvider>
      </BrowserRouter>
    </TooltipProvider>
  </QueryClientProvider>
);

export default App;
