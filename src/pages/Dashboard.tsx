import { DashboardLayout } from "@/components/layout/DashboardLayout";
import { useQuery } from "@tanstack/react-query";
import { supabase } from "@/integrations/supabase/client";
import { formatPKR, formatNumber } from "@/lib/format";
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
  History
} from "lucide-react";

import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import { useNavigate } from "react-router-dom";
import { GettingStarted } from "@/components/dashboard/GettingStarted";

export default function Dashboard() {
  const navigate = useNavigate();
  const todayIso = new Date().toISOString().split('T')[0];
  const todayLabel = new Date().toLocaleDateString('en-PK', {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  });

  const { data: stats, isLoading } = useQuery({
    queryKey: ['dashboard-analytics-v11-2'],
    queryFn: async () => {
      const today = new Date().toISOString().split('T')[0];
      const { data, error } = await (supabase as any).rpc('get_dashboard_v11_3_analytics', { p_date: today });
      if (error) throw error;

      const res = data[0];
      // Map v11.3 monthly columns to UI expectations
      return {
        ...res,
        total_sales: res.sales_monthly,
        total_purchases: res.purchases_monthly,
        // market_balance is now calculated in SQL
        overdue_count: 0
      };
    }
  });

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

  const dashboardMarket = marketStats || {
    receivables: stats?.receivables || 0,
    payables: stats?.payables || 0,
    market_balance: stats?.market_balance || 0,
  };

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

  return (

    <DashboardLayout>
      <div className="max-w-7xl mx-auto pb-20 px-0 sm:px-4 space-y-6">
        <div className="report-header">
          <h1 className="report-title">Operations Control Center</h1>
          <p className="report-subtitle">Real-time Financial & Operational Audit</p>
        </div>

        {/* --- MAIN KPI ROW --- */}
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <div className="bg-white border border-[var(--color-card-border)] border-t-[3px] border-t-[var(--color-primary)] rounded-xl shadow-sm p-5 flex flex-col gap-1 min-w-0">
            <span className="text-[11px] font-semibold uppercase text-[var(--color-text-muted)] tracking-[0.08em]">Sales (Current Month)</span>
            <span className="text-[26px] font-bold text-[var(--color-primary)] num-audit tracking-tight break-words">{formatPKR(stats?.total_sales || 0)}</span>
            <span className="text-[11px] font-medium text-[var(--color-text-muted)] uppercase mt-1">As of {todayLabel}</span>
          </div>

          <div className="bg-white border border-[var(--color-card-border)] border-t-[3px] border-t-[var(--color-text-muted)] rounded-xl shadow-sm p-5 flex flex-col gap-1 min-w-0">
            <span className="text-[11px] font-semibold uppercase text-[var(--color-text-muted)] tracking-[0.08em]">Purchases (Current Month)</span>
            <span className="text-[26px] font-bold text-[var(--color-text-primary)] num-audit tracking-tight break-words">{formatPKR(stats?.total_purchases || 0)}</span>
            <span className="text-[11px] font-medium text-[var(--color-text-muted)] uppercase mt-1">As of {todayLabel}</span>
          </div>

          <div className="bg-white border border-[var(--color-card-border)] border-t-[3px] border-t-[var(--color-success)] rounded-xl shadow-sm p-5 flex flex-col gap-1 min-w-0">
            <span className="text-[11px] font-semibold uppercase text-[var(--color-text-muted)] tracking-[0.08em]">Market Receivables</span>
            <span className="text-[26px] font-bold text-[var(--color-success)] num-audit tracking-tight break-words">{formatPKR(dashboardMarket.receivables)}</span>
            <span className="text-[11px] font-medium text-[var(--color-text-muted)] uppercase mt-1">Total Outstanding (Lena)</span>
          </div>

          <div className="bg-white border border-[var(--color-card-border)] border-t-[3px] border-t-[var(--color-danger)] rounded-xl shadow-sm p-5 flex flex-col gap-1 min-w-0">
            <span className="text-[11px] font-semibold uppercase text-[var(--color-text-muted)] tracking-[0.08em]">Market Payables</span>
            <span className="text-[26px] font-bold text-[var(--color-danger)] num-audit tracking-tight break-words">{formatPKR(dashboardMarket.payables)}</span>
            <span className="text-[11px] font-medium text-[var(--color-text-muted)] uppercase mt-1">Total Supplier Dues (Dena)</span>
          </div>
        </div>

        {/* --- MIDDLE SECTION: STOCK & ALERTS --- */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          {/* Stock Movement Mini-Table */}
          <div className="lg:col-span-2 space-y-5">
            <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-2 pb-3">
              <h3 className="text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--color-text-muted)]">Inventory Levels (Physical)</h3>
              <span className="text-[11px] font-medium text-[var(--color-text-muted)] uppercase tracking-[0.08em]">Latest System Computation</span>
            </div>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
              <InventoryMiniCards />
            </div>
          </div>

          {/* Alerts & Audit Summary */}
          <div className="space-y-5">
            <div className="border border-[var(--color-card-border)] bg-white rounded-xl shadow-sm p-4 space-y-4">
              <h3 className="text-[11px] font-semibold uppercase tracking-[0.1em] text-[var(--color-text-muted)] border-b border-[#F4F4F5] pb-3">Audit Trail (Recent)</h3>
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

            <div className="bg-white border border-[var(--color-card-border)] rounded-xl shadow-sm px-5 py-4 flex flex-col sm:flex-row sm:justify-between sm:items-center gap-3">
              <div className="flex flex-col gap-0.5">
                <span className="text-[11px] font-semibold uppercase text-[var(--color-text-muted)] tracking-[0.08em]">Net Market Position</span>
                <span className={cn("text-xs font-semibold", dashboardMarket.market_balance >= 0 ? "text-[var(--color-success)]" : "text-[var(--color-danger)]")}>
                  {dashboardMarket.market_balance >= 0 ? "Dr (Net Asset)" : "Cr (Net Liability)"}
                </span>
              </div>
              <span className={cn("text-[22px] font-bold num-audit tracking-tight break-words", dashboardMarket.market_balance >= 0 ? "text-[var(--color-success)]" : "text-[var(--color-danger)]")}>{formatPKR(Math.abs(dashboardMarket.market_balance))}</span>
            </div>
          </div>
        </div>

        {/* TEMPORARY ONBOARDING SECTION:
            TODO: Remove this onboarding section before final production deployment if requested by the client. */}
        <GettingStarted />
      </div>
    </DashboardLayout>

  );
}


function InventoryMiniCards() {
  const { data: inventory, isLoading } = useQuery({
    queryKey: ['inventory-mini-v10'],
    queryFn: async () => {
      const { data, error } = await (supabase as any).rpc('get_stock_movement', {
        p_start_date: new Date().toISOString().split('T')[0],
        p_end_date: new Date().toISOString().split('T')[0]
      });
      if (error) return [];
      return data;
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

      // Filter out duplicate vouchers to show one line per transaction
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

      return uniqueVouchers.slice(0, 5); // Just show last 5 unique transactions
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
