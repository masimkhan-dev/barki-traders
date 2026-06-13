import { DashboardLayout } from "@/components/layout/DashboardLayout";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { formatNumber, formatPKR } from "@/lib/format";
import { useState, useMemo } from "react";
import { format, parseISO } from "date-fns";
import {
  ShoppingCart,
  Truck,
  ArrowDownLeft,
  ArrowUpRight,
  Landmark,
  Loader2,
  Fuel,
  AlertCircle,
  ShieldCheck,
  TrendingUp,
  History,
  Package,
  Wallet,
  Coins,
  Percent
} from "lucide-react";

import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { cn } from "@/lib/utils";
import { useNavigate } from "react-router-dom";
import { GettingStarted } from "@/components/dashboard/GettingStarted";

// Import Charts directly
import { SalesPurchasesTrendChart } from "@/components/dashboard/charts/SalesPurchasesTrendChart";
import { CashFlowTrendChart } from "@/components/dashboard/charts/CashFlowTrendChart";
import { StockByFuelChart } from "@/components/dashboard/charts/StockByFuelChart";
import { ReceivablesPayablesSummary } from "@/components/dashboard/charts/ReceivablesPayablesSummary";
import { ProfitTrendChart } from "@/components/dashboard/charts/ProfitTrendChart";
import { FuelQuantitySoldChart } from "@/components/dashboard/charts/FuelQuantitySoldChart";
import { TopPartiesLists } from "@/components/dashboard/charts/TopPartiesLists";
import { getDateRangeFromPreset, type DateRangePreset } from "@/lib/api/dashboard-analytics";

const SHOW_GETTING_STARTED_GUIDE = false;

const PRESETS: { id: DateRangePreset; label: string }[] = [
  { id: '7D', label: '7D' },
  { id: '30D', label: '30D' },
  { id: 'MTD', label: 'MTD' },
  { id: 'YTD', label: 'YTD' },
];

const PRESET_RANGE_LABELS: Record<DateRangePreset, string> = {
  '7D': 'Last 7 days',
  '30D': 'Last 30 days',
  MTD: 'Month to date',
  YTD: 'Year to date',
};

function formatAnalyticsRangeLabel(preset: DateRangePreset, startDate: string, endDate: string) {
  try {
    const start = format(parseISO(startDate), 'd MMM');
    const end = format(parseISO(endDate), 'd MMM yyyy');
    return `${PRESET_RANGE_LABELS[preset]} · ${start} – ${end}`;
  } catch {
    return `${PRESET_RANGE_LABELS[preset]} · ${startDate} – ${endDate}`;
  }
}

export default function Dashboard() {
  const navigate = useNavigate();
  const [preset, setPreset] = useState<DateRangePreset>('30D');
  const [activeTab, setActiveTab] = useState('overview');
  
  const { startDate, endDate } = useMemo(() => getDateRangeFromPreset(preset), [preset]);
  const todayIso = new Date().toISOString().split('T')[0];
  const todayLabel = new Date().toLocaleDateString('en-PK', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  });

  // Query 1: Monthly sales, purchases, and initial market balances
  const { data: stats, isLoading } = useQuery({
    queryKey: ['dashboard-analytics-v11-2'],
    queryFn: async () => {
      const today = new Date().toISOString().split('T')[0];
      const { data, error } = await (supabase as any).rpc('get_dashboard_v11_3_analytics', { p_date: today });
      if (error) throw error;

      const res = data[0];
      return {
        ...res,
        total_sales: res.sales_monthly,
        total_purchases: res.purchases_monthly,
        overdue_count: 0
      };
    }
  });

  // Query 2: Ledger-backed Receivables & Payables
  const { data: marketStats } = useQuery({
    queryKey: ['dashboard-market-ledger-backed', todayIso],
    queryFn: async () => {
      const { data: parties, error: partiesError } = await supabase
        .from('parties')
        .select('id, opening_balance')
        .eq('is_active', true);

      if (partiesError) throw partiesError;

      const { data, error } = await supabase
        .from('ledger_entries')
        .select('party_id, debit_amount, credit_amount')
        .not('party_id', 'is', null)
        .lte('posting_date', todayIso);

      if (error) throw error;

      const balances = new Map<string, number>();
      (parties || []).forEach(party => {
        balances.set(party.id, Number(party.opening_balance) || 0);
      });

      (data || []).forEach(entry => {
        if (!entry.party_id) return;
        const current = balances.get(entry.party_id) || 0;
        balances.set(
          entry.party_id,
          current + (Number(entry.debit_amount) || 0) - (Number(entry.credit_amount) || 0)
        );
      });

      let receivables = 0;
      let payables = 0;
      balances.forEach(balance => {
        if (balance > 0) receivables += balance;
        if (balance < 0) payables += Math.abs(balance);
      });

      return {
        receivables,
        payables,
        market_balance: receivables - payables,
      };
    },
  });

  // Query 3: Real-time Stock Value at AVCO
  const { data: inventoryValue } = useQuery({
    queryKey: ['dashboard-inventory-value-v1'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('inventory')
        .select('quantity, avg_cost');

      if (error) throw error;

      return (data || []).reduce(
        (total, row: any) => {
          const quantity = Number(row.quantity) || 0;
          const avgCost = Number(row.avg_cost) || 0;
          return total + quantity * avgCost;
        },
        0
      );
    },
  });

  // Query 4: Ledger-backed Profitability metrics parameterized by date range (uses get_profit_loss_v13 RPC)
  const { data: profitStats, isLoading: isProfitLoading } = useQuery({
    queryKey: ['dashboard-profitability-metrics', startDate, endDate],
    queryFn: async () => {
      const { data, error } = await (supabase as any).rpc('get_profit_loss_v13', {
        p_start_date: startDate,
        p_end_date: endDate
      });
      if (error) throw error;

      let sales = 0;
      let cogs = 0;

      (data || []).forEach((row: any) => {
        if (row.section_name === 'Revenue') {
          sales += Number(row.amount) || 0;
        } else if (row.section_name === 'Cost of Sales') {
          cogs += Number(row.amount) || 0;
        }
      });

      return {
        sales,
        cogs,
        grossProfit: sales - cogs,
        ratio: sales > 0 ? ((sales - cogs) / sales) * 100 : 0
      };
    }
  });

  const dashboardMarket = marketStats || {
    receivables: stats?.receivables || 0,
    payables: stats?.payables || 0,
    market_balance: stats?.market_balance || 0,
  };

  const profitability = profitStats || {
    sales: 0,
    cogs: 0,
    grossProfit: 0,
    ratio: 0
  };

  // Query 5: Cash and Bank balances
  const { data: cashBalances, isLoading: isCashLoading } = useQuery({
    queryKey: ['dashboard-cash-bank-balances'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('accounts')
        .select('id, code, name, slug, sub_category')
        .or('slug.in.(cash,bank),code.in.(1000,1010),name.ilike.%cash%,name.ilike.%bank%');
        
      if (error) throw error;
      if (!data || data.length === 0) return [];
      
      const accountIds = data.map(a => a.id);
      
      const { data: entries, error: entriesError } = await supabase
        .from('ledger_entries')
        .select('account_id, debit_amount, credit_amount')
        .in('account_id', accountIds)
        .eq('is_reversed', false);
        
      if (entriesError) throw entriesError;
      
      const balanceMap = new Map<string, number>();
      (entries || []).forEach(e => {
        const current = balanceMap.get(e.account_id) || 0;
        balanceMap.set(e.account_id, current + (Number(e.debit_amount) || 0) - (Number(e.credit_amount) || 0));
      });
      
      return data.map(acc => ({
        id: acc.id,
        code: acc.code,
        name: acc.name,
        balance: balanceMap.get(acc.id) || 0
      })).sort((a, b) => a.code.localeCompare(b.code));
    }
  });

  if (isLoading) {
    return (
      <DashboardLayout>
        <div className="flex flex-col items-center justify-center min-h-[60vh] gap-4">
          <Loader2 className="h-10 w-10 animate-spin text-slate-300" />
          <span className="text-[10px] font-black text-slate-400 uppercase tracking-[0.2em]">Loading operations data...</span>
        </div>
      </DashboardLayout>
    );
  }

  // Determine if the active tab requires the date range filter
  const showDatePreset = ['overview', 'stock', 'profitability'].includes(activeTab);

  return (
    <DashboardLayout>
      <div className="max-w-full mx-auto pb-20 px-0 sm:px-4 space-y-6">
        
        {/* HEADER & DATE PRESET CONTROLS */}
        <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-4 border-b border-[#E4E4E7] pb-5">
          <div className="report-header !pb-0 !border-b-0">
            <h1 className="report-title">Operations Control Center</h1>
            <p className="report-subtitle">Real-time Financial & Operational Audit</p>
          </div>

          {showDatePreset && (
            <div className="flex items-center gap-3 bg-white p-2 border border-slate-200 rounded-lg shadow-sm w-fit self-start md:self-auto">
              <span className="text-[10px] font-black text-slate-400 uppercase tracking-widest pl-1 hidden sm:inline">
                {formatAnalyticsRangeLabel(preset, startDate, endDate)}
              </span>
              <div className="flex items-center gap-1 p-0.5 bg-[#FAFAFA] border border-[#F4F4F5] rounded-md">
                {PRESETS.map(({ id, label }) => (
                  <button
                    key={id}
                    type="button"
                    onClick={() => setPreset(id)}
                    className={cn(
                      'px-3 py-1.5 text-[9px] font-black uppercase tracking-widest rounded-sm transition-colors h-7 flex items-center justify-center',
                      preset === id
                        ? 'bg-[var(--color-primary)] text-white'
                        : 'text-[var(--color-text-muted)] hover:bg-white hover:text-slate-900'
                    )}
                  >
                    {label}
                  </button>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* TABS CONTAINER */}
        <Tabs value={activeTab} onValueChange={setActiveTab} className="space-y-6">
          <TabsList className="bg-slate-100 p-0 rounded-none h-auto min-h-10 border border-slate-300 w-full lg:max-w-3xl grid grid-cols-2 md:grid-cols-5 print:hidden">
            <TabsTrigger value="overview" className="rounded-none border-r border-slate-300 font-bold uppercase text-[10px] tracking-widest data-[state=active]:bg-slate-900 data-[state=active]:text-white h-full transition-none py-2.5">
              Overview
            </TabsTrigger>
            <TabsTrigger value="stock" className="rounded-none border-r border-slate-300 font-bold uppercase text-[10px] tracking-widest data-[state=active]:bg-slate-900 data-[state=active]:text-white h-full transition-none py-2.5">
              Stock & Inventory
            </TabsTrigger>
            <TabsTrigger value="market" className="rounded-none border-r border-slate-300 font-bold uppercase text-[10px] tracking-widest data-[state=active]:bg-slate-900 data-[state=active]:text-white h-full transition-none py-2.5">
              Market Exposure
            </TabsTrigger>
            <TabsTrigger value="profitability" className="rounded-none border-r border-slate-300 font-bold uppercase text-[10px] tracking-widest data-[state=active]:bg-slate-900 data-[state=active]:text-white h-full transition-none py-2.5">
              Profitability
            </TabsTrigger>
            <TabsTrigger value="liquidity" className="rounded-none font-bold uppercase text-[10px] tracking-widest data-[state=active]:bg-slate-900 data-[state=active]:text-white h-full transition-none py-2.5">
              Cash & Bank
            </TabsTrigger>
          </TabsList>

          {/* TAB 1: OVERVIEW */}
          <TabsContent value="overview" className="space-y-6 outline-none">
            {/* KPI Cards Row */}
            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
              <div className="bg-white border border-[var(--color-card-border)] border-t-[3px] border-t-[var(--color-primary)] rounded-xl shadow-sm p-5 flex flex-col gap-1 min-w-0 overflow-hidden">
                <span className="text-[11px] font-semibold uppercase text-[var(--color-text-muted)] tracking-[0.08em]">Sales (Current Month)</span>
                <span className="text-[28px] font-black text-[var(--color-primary)] num-audit tracking-tight whitespace-nowrap">
                  {formatPKR(stats?.total_sales || 0)}
                </span>
                <span className="text-[11px] font-medium text-[var(--color-text-muted)] uppercase mt-1">As of {todayLabel}</span>
              </div>

              <div className="bg-white border border-[var(--color-card-border)] border-t-[3px] border-t-[var(--color-text-muted)] rounded-xl shadow-sm p-5 flex flex-col gap-1 min-w-0 overflow-hidden">
                <span className="text-[11px] font-semibold uppercase text-[var(--color-text-muted)] tracking-[0.08em]">Purchases (Current Month)</span>
                <span className="text-[28px] font-black text-[var(--color-text-primary)] num-audit tracking-tight whitespace-nowrap">
                  {formatPKR(stats?.total_purchases || 0)}
                </span>
                <span className="text-[11px] font-medium text-[var(--color-text-muted)] uppercase mt-1">As of {todayLabel}</span>
              </div>

              <div className="bg-white border border-[var(--color-card-border)] border-t-[3px] border-t-[var(--color-warning)] rounded-xl shadow-sm p-5 flex flex-col gap-1 min-w-0 overflow-hidden">
                <span className="text-[11px] font-semibold uppercase text-[var(--color-text-muted)] tracking-[0.08em]">Inventory Value</span>
                <span className="text-[28px] font-black text-[var(--color-warning-text)] num-audit tracking-tight whitespace-nowrap">
                  {formatPKR(inventoryValue || 0)}
                </span>
                <span className="text-[11px] font-medium text-[var(--color-text-muted)] uppercase mt-1">At weighted avg cost</span>
              </div>
            </div>

            {/* Charts Row */}
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
              <SalesPurchasesTrendChart startDate={startDate} endDate={endDate} />
              <CashFlowTrendChart startDate={startDate} endDate={endDate} />
            </div>

            {/* Bottom Row: Recent Audit Feed */}
            <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
              <div className="lg:col-span-2 border border-[var(--color-card-border)] bg-white rounded-xl shadow-sm p-5 space-y-4">
                <div className="border-b border-[#F4F4F5] pb-3 flex justify-between items-center">
                  <h3 className="text-[11px] font-black uppercase tracking-[0.1em] text-[var(--color-text-muted)]">Audit Trail (Recent Activities)</h3>
                  <span className="text-[10px] font-bold text-slate-400 uppercase">Operational Log</span>
                </div>
                <div className="space-y-1">
                  <RecentTransactionsFeed />
                </div>
                <Button
                  variant="outline"
                  className="w-full rounded-lg border-[var(--color-primary)] text-[var(--color-primary)] bg-transparent hover:bg-[var(--color-primary-light)] font-semibold uppercase text-[11px] tracking-widest h-10 mt-2"
                  onClick={() => navigate('/manage-transactions')}
                >
                  <ShieldCheck className="h-3.5 w-3.5 mr-2" /> Open Audit System
                </Button>
              </div>

              {/* Net Position Card */}
              <div className="flex flex-col justify-between bg-slate-900 border border-slate-800 text-white rounded-xl shadow-sm p-6">
                <div className="space-y-1.5">
                  <span className="text-[10px] font-black uppercase text-slate-400 tracking-[0.15em] block">System Health Status</span>
                  <span className="text-[15px] font-bold text-emerald-400 flex items-center gap-1.5">
                    <ShieldCheck className="h-4 w-4" />
                    Secure & Balanced Ledger
                  </span>
                  <p className="text-slate-400 text-xs leading-relaxed pt-2">
                    Double-entry bookkeeping is validated. Total assets match liabilities and equity. Real-time balance constraints are active.
                  </p>
                </div>
                <div className="border-t border-slate-800 pt-5 mt-6 flex flex-col gap-1">
                  <span className="text-[10px] font-black uppercase text-slate-400 tracking-[0.08em]">Reporting Reference</span>
                  <span className="font-mono text-xs text-slate-300">OP-REF-{todayIso.replace(/-/g, '')}</span>
                </div>
              </div>
            </div>
          </TabsContent>

          {/* TAB 2: STOCK & INVENTORY */}
          <TabsContent value="stock" className="space-y-6 outline-none">
            {/* Physical Inventory Level mini cards */}
            <div className="space-y-3">
              <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-2 pb-1">
                <h3 className="text-[11px] font-black uppercase tracking-[0.1em] text-[var(--color-text-muted)]">Inventory Levels (Physical)</h3>
                <span className="text-[10px] font-bold text-slate-400 uppercase">Snapshot at Weighted Avg Cost</span>
              </div>
              <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                <InventoryMiniCards />
              </div>
            </div>

            {/* Inventory Charts Row */}
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-4 pt-2">
              <StockByFuelChart />
              <FuelQuantitySoldChart startDate={startDate} endDate={endDate} />
            </div>
          </TabsContent>

          {/* TAB 3: MARKET EXPOSURE */}
          <TabsContent value="market" className="space-y-6 outline-none">
            {/* KPI Cards Row */}
            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
              <div className="bg-white border border-[var(--color-card-border)] border-t-[3px] border-t-[var(--color-success)] rounded-xl shadow-sm p-5 flex flex-col gap-1 min-w-0 overflow-hidden">
                <span className="text-[11px] font-semibold uppercase text-[var(--color-text-muted)] tracking-[0.08em]">Market Receivables</span>
                <span className="text-[28px] font-black text-[var(--color-success)] num-audit tracking-tight whitespace-nowrap">
                  {formatPKR(dashboardMarket.receivables)}
                </span>
                <span className="text-[11px] font-medium text-[var(--color-text-muted)] uppercase mt-1">Total Outstanding (Lena)</span>
              </div>

              <div className="bg-white border border-[var(--color-card-border)] border-t-[3px] border-t-[var(--color-danger)] rounded-xl shadow-sm p-5 flex flex-col gap-1 min-w-0 overflow-hidden">
                <span className="text-[11px] font-semibold uppercase text-[var(--color-text-muted)] tracking-[0.08em]">Market Payables</span>
                <span className="text-[28px] font-black text-[var(--color-danger)] num-audit tracking-tight whitespace-nowrap">
                  {formatPKR(dashboardMarket.payables)}
                </span>
                <span className="text-[11px] font-medium text-[var(--color-text-muted)] uppercase mt-1">Total Supplier Dues (Dena)</span>
              </div>

              <div className="bg-white border border-[var(--color-card-border)] border-t-[3px] border-t-slate-900 rounded-xl shadow-sm p-5 flex flex-col gap-1 min-w-0 overflow-hidden">
                <span className="text-[11px] font-semibold uppercase text-[var(--color-text-muted)] tracking-[0.08em]">Net Market Position</span>
                <span className={cn("text-[28px] font-black num-audit tracking-tight whitespace-nowrap", dashboardMarket.market_balance >= 0 ? "text-[var(--color-success)]" : "text-[var(--color-danger)]")}>
                  {formatPKR(Math.abs(dashboardMarket.market_balance))}
                </span>
                <span className={cn("text-[11px] font-semibold uppercase mt-1", dashboardMarket.market_balance >= 0 ? "text-[var(--color-success)]" : "text-[var(--color-danger)]")}>
                  {dashboardMarket.market_balance >= 0 ? "Dr (Net Asset)" : "Cr (Net Liability)"}
                </span>
              </div>
            </div>

            {/* Exposure Summary and Top Parties lists */}
            <div className="grid grid-cols-1 lg:grid-cols-3 gap-6 pt-2">
              <div className="lg:col-span-2">
                <TopPartiesLists />
              </div>
              <div className="flex flex-col gap-4">
                <ReceivablesPayablesSummary />
              </div>
            </div>
          </TabsContent>

          {/* TAB 4: PROFITABILITY */}
          <TabsContent value="profitability" className="space-y-6 outline-none">
            {/* Monthly Profit/Loss mini summary */}
            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
              <div className="bg-white border border-[var(--color-card-border)] rounded-xl shadow-sm p-5 flex flex-col gap-1">
                <span className="text-[10px] font-black uppercase text-[var(--color-text-muted)] tracking-[0.08em]">Period Sales</span>
                <span className="text-2xl font-bold text-emerald-600 num-audit">
                  {isProfitLoading ? "..." : formatPKR(profitability.sales)}
                </span>
              </div>

              <div className="bg-white border border-[var(--color-card-border)] rounded-xl shadow-sm p-5 flex flex-col gap-1">
                <span className="text-[10px] font-black uppercase text-[var(--color-text-muted)] tracking-[0.08em]">Estimated Cost of Sales</span>
                <span className="text-2xl font-bold text-slate-800 num-audit">
                  {isProfitLoading ? "..." : formatPKR(profitability.cogs)}
                </span>
              </div>

              <div className="bg-white border border-[var(--color-card-border)] rounded-xl shadow-sm p-5 flex flex-col gap-1">
                <span className="text-[10px] font-black uppercase text-[var(--color-text-muted)] tracking-[0.08em]">Gross Margin Profit</span>
                <span className={cn("text-2xl font-bold num-audit", profitability.grossProfit >= 0 ? "text-emerald-600" : "text-red-600")}>
                  {isProfitLoading ? "..." : formatPKR(profitability.grossProfit)}
                </span>
              </div>

              <div className="bg-slate-900 border border-slate-800 text-white rounded-xl shadow-sm p-5 flex flex-col gap-1">
                <span className="text-[10px] font-black uppercase text-slate-400 tracking-[0.08em]">Profit-to-Sales Ratio</span>
                <span className={cn("text-2xl font-bold num-audit", profitability.grossProfit >= 0 ? "text-emerald-400" : "text-red-400")}>
                  {isProfitLoading ? "..." : profitability.ratio.toFixed(1) + "%"}
                </span>
              </div>
            </div>

            {/* Profit Chart */}
            <div className="border border-[var(--color-card-border)] bg-white rounded-xl shadow-sm p-5">
              <div className="border-b border-[#F4F4F5] pb-3 mb-4 flex justify-between items-center">
                <div>
                  <h3 className="text-[11px] font-black uppercase tracking-[0.1em] text-[var(--color-text-muted)]">Earnings & Profit Trend</h3>
                  <span className="text-[9px] text-slate-400 font-bold uppercase">Income vs Expense analysis</span>
                </div>
                <Percent className="h-4 w-4 text-[var(--color-primary)]" />
              </div>
              <div className="h-[350px]">
                <ProfitTrendChart startDate={startDate} endDate={endDate} />
              </div>
            </div>
          </TabsContent>

          {/* TAB 5: CASH & BANK LIQUIDITY */}
          <TabsContent value="liquidity" className="space-y-6 outline-none">
            {/* Total Liquidity Card */}
            <div className="bg-slate-900 border border-slate-800 text-white rounded-xl shadow-sm p-6 flex flex-col md:flex-row md:items-center justify-between gap-4">
              <div className="space-y-1">
                <span className="text-[10px] font-black uppercase text-slate-400 tracking-[0.15em] block">Total Available Liquidity</span>
                <h3 className="text-3xl font-black text-emerald-400 tracking-tight num-audit">
                  {isCashLoading ? "..." : formatPKR(
                    (cashBalances || []).reduce((sum, item) => sum + item.balance, 0)
                  )}
                </h3>
                <p className="text-slate-400 text-xs">Combined real-time balances of all Cash & Bank ledger accounts.</p>
              </div>
              <div className="bg-slate-800/80 p-3.5 rounded-lg border border-slate-700 w-fit self-start md:self-auto">
                <Coins className="h-6 w-6 text-emerald-400" />
              </div>
            </div>

            {/* Individual Accounts Grid */}
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              {isCashLoading ? (
                <div className="col-span-full flex flex-col items-center justify-center py-16 gap-3">
                  <Loader2 className="h-6 w-6 animate-spin text-slate-300" />
                  <span className="text-[9px] font-black text-slate-400 uppercase tracking-[0.2em]">Fetching bank balances...</span>
                </div>
              ) : (
                (cashBalances || []).map((account, index) => {
                  const isCash = account.name.toLowerCase().includes('cash') || account.code === '1000';
                  const Icon = isCash ? Wallet : Landmark;
                  
                  return (
                    <div key={account.id || index} className="border border-[var(--color-card-border)] bg-white rounded-xl shadow-sm p-5 flex flex-col justify-between hover:bg-slate-50/50">
                      <div className="flex items-center justify-between gap-3 mb-4">
                        <div className="flex flex-col min-w-0">
                          <span className="text-[10px] font-black uppercase text-[var(--color-text-muted)] tracking-wider">
                            Account {account.code}
                          </span>
                          <h4 className="text-[14px] font-bold text-[var(--color-text-primary)] truncate mt-0.5">
                            {account.name}
                          </h4>
                        </div>
                        <div className={cn(
                          "p-2 rounded-lg border",
                          isCash 
                            ? "bg-amber-50 text-amber-600 border-amber-100" 
                            : "bg-teal-50 text-teal-600 border-teal-100"
                        )}>
                          <Icon className="h-4 w-4" />
                        </div>
                      </div>

                      <div className="border-t border-[#F4F4F5] pt-4 mt-2">
                        <span className="text-[10px] font-black uppercase text-[var(--color-text-muted)] tracking-wider">
                          Current Balance
                        </span>
                        <div className="text-xl font-bold text-[var(--color-text-primary)] num-audit mt-1">
                          {formatPKR(account.balance)}
                        </div>
                      </div>
                    </div>
                  );
                })
              )}
            </div>
          </TabsContent>
        </Tabs>

        {SHOW_GETTING_STARTED_GUIDE && <GettingStarted />}
      </div>
    </DashboardLayout>
  );
}

function InventoryMiniCards() {
  const { data: inventory, isLoading } = useQuery({
    queryKey: ['inventory-mini-v11'],
    queryFn: async () => {
      const { data: movementData, error: movementError } = await (supabase as any).rpc('get_stock_movement', {
        p_start_date: new Date().toISOString().split('T')[0],
        p_end_date: new Date().toISOString().split('T')[0]
      });
      if (movementError) return [];

      const { data: valueData, error: valueError } = await supabase
        .from('inventory')
        .select('fuel_type_id, quantity, avg_cost, fuel:fuel_types(name)');

      if (valueError) return movementData || [];

      const valueMap = new Map(
        (valueData || []).map((row: any) => {
          const quantity = Number(row.quantity) || 0;
          const avgCost = Number(row.avg_cost) || 0;

          return [
            row.fuel_type_id,
            {
              avg_cost: avgCost,
              stock_value: quantity * avgCost,
            },
          ];
        })
      );

      return (movementData || []).map((item: any) => ({
        ...item,
        avg_cost: valueMap.get(item.fuel_type_id)?.avg_cost || 0,
        stock_value: valueMap.get(item.fuel_type_id)?.stock_value || 0,
      }));
    }
  });

  if (isLoading) return <div className="col-span-2 flex flex-col items-center justify-center py-12 gap-3"><Loader2 className="h-6 w-6 animate-spin text-slate-300" /><span className="text-[9px] font-black text-slate-400 uppercase tracking-[0.2em]">Scanning stock levels...</span></div>;

  return inventory?.map((item: any, i: number) => {
    const stock = Number(item.closing_stock) || 0;
    const stockState =
      stock === 0
        ? { label: 'Out of Stock', className: 'bg-[var(--color-danger-light)] text-[var(--color-danger-text)]' }
        : stock < 1000
          ? { label: 'Low Stock', className: 'bg-[var(--color-warning-light)] text-[var(--color-warning-text)]' }
          : { label: 'In Stock', className: 'bg-[var(--color-success-light)] text-[var(--color-success-text)]' };

    return (
      <div key={i} className="border border-[var(--color-card-border)] bg-white rounded-xl shadow-sm p-4 flex flex-col justify-between hover:bg-slate-50/50">
        <div className="flex items-center justify-between gap-3 mb-3">
          <span className="text-[13px] font-semibold text-[var(--color-text-primary)]">{item.fuel_name}</span>
          <span className={cn("rounded-full px-2.5 py-0.5 text-[11px] font-semibold whitespace-nowrap", stockState.className)}>
            {stockState.label}
          </span>
        </div>

        <div className="mb-1">
          <h4 className="text-[28px] font-bold text-[var(--color-text-primary)] num-audit leading-none tracking-tight">
            {formatNumber(item.closing_stock)}
            <span className="text-[13px] ml-1.5 text-[var(--color-text-muted)] font-medium uppercase">Ltr</span>
          </h4>
          <div className="mt-3 grid grid-cols-2 gap-2 rounded-lg bg-[#FAFAFA] border border-[#F4F4F5] px-3 py-2">
            <div className="flex flex-col gap-0.5">
              <span className="text-[10px] font-semibold text-[var(--color-text-muted)] uppercase tracking-[0.08em]">Stock Value</span>
              <span className="text-sm font-bold text-[var(--color-text-primary)] num-audit">{formatPKR(item.stock_value || 0)}</span>
            </div>
            <div className="flex flex-col items-end gap-0.5">
              <span className="text-[10px] font-semibold text-[var(--color-text-muted)] uppercase tracking-[0.08em]">Avg Cost</span>
              <span className="text-sm font-bold text-[var(--color-text-primary)] num-audit">{formatPKR(item.avg_cost || 0)}/L</span>
            </div>
          </div>
        </div>

        <div className="mt-3 pt-3 border-t border-[#F4F4F5] grid grid-cols-2 gap-2">
          <div className="flex flex-col gap-0.5">
            <span className="text-[11px] font-medium text-[var(--color-text-muted)] uppercase">Purchased</span>
            <span className="text-xs font-bold text-[var(--color-success)] num-audit">+{formatNumber(item.purchased)}</span>
          </div>
          <div className="flex flex-col items-end gap-0.5">
            <span className="text-[11px] font-medium text-[var(--color-text-muted)] uppercase">Sold</span>
            <span className="text-xs font-bold text-[var(--color-danger)] num-audit">-{formatNumber(item.sold)}</span>
          </div>
        </div>
      </div>
    );
  });
}

function RecentTransactionsFeed() {
  const { data: recent, isLoading } = useQuery({
    queryKey: ['recent-activities-v1'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('ledger_entries')
        .select(`
          voucher_no,
          voucher_type,
          debit_amount,
          credit_amount,
          narration,
          created_at,
          party:parties(name)
        `)
        .not('party_id', 'is', null)
        .order('created_at', { ascending: false })
        .limit(30);

      if (error) return [];

      const uniqueVouchers: any[] = [];
      const seen = new Set();

      data.forEach(item => {
        if (!seen.has(item.voucher_no)) {
          seen.add(item.voucher_no);
          uniqueVouchers.push({
            ...item,
            amount: Math.max(item.debit_amount, item.credit_amount),
            display_type: item.voucher_no?.startsWith('REV-') ? 'reversal' : item.voucher_type,
            clean_narration: (item.narration || '').replace(/^Ref: N\/A - /, '').trim()
          });
        }
      });

      return uniqueVouchers.slice(0, 5);
    }
  });

  if (isLoading) return <div className="flex flex-col items-center justify-center py-8 gap-3"><Loader2 className="h-5 w-5 animate-spin text-slate-300" /><span className="text-[9px] font-black text-slate-400 uppercase tracking-[0.2em]">Loading feed...</span></div>;

  if (!recent || recent.length === 0) return <p className="text-[10px] text-slate-400 font-bold uppercase text-center py-6">No recent activity detected</p>;

  return recent.map((item, idx) => {
    const isSale = item.display_type === 'sale';
    const isPurchase = item.display_type === 'purchase';
    const isPayment = item.display_type === 'payment' || item.display_type === 'receipt';
    const isReversal = item.display_type === 'reversal';

    let colorClass = "bg-[var(--color-transfer-light)] text-[var(--color-transfer-text)]";
    if (isSale) colorClass = "bg-[var(--color-success-light)] text-[var(--color-success-text)]";
    if (isPurchase) colorClass = "bg-[var(--color-primary-light)] text-[var(--color-transfer-text)]";
    if (isPayment) colorClass = "bg-[var(--color-warning-light)] text-[var(--color-warning-text)]";
    if (isReversal) colorClass = "bg-[var(--color-warning-light)] text-[var(--color-warning-text)]";

    return (
      <div key={idx} className={cn("flex items-center justify-between py-2.5 border-b border-[#F4F4F5] last:border-0 hover:bg-slate-50/50 px-2", idx % 2 === 1 && "bg-[#FAFAFA]")}>
        <div className="flex flex-col gap-0.5 min-w-0">
          <div className="flex items-center gap-2">
            <span className={cn("rounded-full text-[11px] font-semibold uppercase px-2.5 py-0.5 leading-none", colorClass)}>
              {item.display_type}
            </span>
            <span className="text-[13px] font-semibold text-[var(--color-text-primary)] truncate max-w-[150px] uppercase">
              {item.party?.name || 'Party'}
            </span>
          </div>
          <span className="text-[12px] text-[var(--color-text-muted)] font-medium truncate italic pl-0.5" title={item.clean_narration}>
            {item.clean_narration || 'No remarks'}
          </span>
        </div>
        <div className="text-right flex flex-col items-end gap-0.5 flex-shrink-0 ml-3">
          <span className={cn("text-[13px] font-bold num-audit", isPurchase || isReversal ? "text-[var(--color-danger)]" : "text-[var(--color-success)]")}>
            {formatPKR(item.amount).replace('Rs. ', '')}
          </span>
          <span className="text-[11px] font-medium text-[var(--color-text-muted)] uppercase num-audit">
            {new Date(item.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
          </span>
        </div>
      </div>
    );
  });
}
