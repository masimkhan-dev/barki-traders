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
      const { data, error } = await supabase
        .from('ledger_entries')
        .select('party_id, debit_amount, credit_amount')
        .not('party_id', 'is', null)
        .lte('posting_date', todayIso);

      if (error) throw error;

      const balances = new Map<string, number>();
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
      <div className="max-w-7xl mx-auto pb-20 px-0 sm:px-4 space-y-8">
        <div className="report-header">
          <h1 className="report-title">Operations Control Center</h1>
          <p className="report-subtitle">Real-time Financial & Operational Audit</p>
        </div>

        {/* --- MAIN KPI ROW --- */}
        <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-4">
          <div className="bg-white border border-slate-200 border-t-4 border-t-slate-900 p-5 flex flex-col gap-1 min-w-0">
            <span className="text-[11px] font-black uppercase text-slate-500 tracking-normal">Sales (Current Month)</span>
            <span className="text-2xl font-black text-slate-900 num-audit tracking-tight break-words">{formatPKR(stats?.total_sales || 0)}</span>
            <span className="text-[11px] font-bold text-slate-400 uppercase mt-1">As of {todayLabel}</span>
          </div>

          <div className="bg-white border border-slate-200 border-t-4 border-t-slate-400 p-5 flex flex-col gap-1 min-w-0">
            <span className="text-[11px] font-black uppercase text-slate-500 tracking-normal">Purchases (Current Month)</span>
            <span className="text-2xl font-black text-slate-700 num-audit tracking-tight break-words">{formatPKR(stats?.total_purchases || 0)}</span>
            <span className="text-[11px] font-bold text-slate-400 uppercase mt-1">As of {todayLabel}</span>
          </div>

          <div className="bg-white border border-slate-200 border-t-4 border-t-emerald-600 p-5 flex flex-col gap-1 min-w-0">
            <span className="text-[11px] font-black uppercase text-emerald-700 tracking-normal">Market Receivables</span>
            <span className="text-2xl font-black text-emerald-700 num-audit tracking-tight break-words">{formatPKR(dashboardMarket.receivables)}</span>
            <span className="text-[11px] font-bold text-emerald-600/60 uppercase mt-1">Total Outstanding (Lena)</span>
          </div>

          <div className="bg-white border border-slate-200 border-t-4 border-t-rose-600 p-5 flex flex-col gap-1 min-w-0">
            <span className="text-[11px] font-black uppercase text-rose-700 tracking-normal">Market Payables</span>
            <span className="text-2xl font-black text-rose-700 num-audit tracking-tight break-words">{formatPKR(dashboardMarket.payables)}</span>
            <span className="text-[11px] font-bold text-rose-600/60 uppercase mt-1">Total Supplier Dues (Dena)</span>
          </div>
        </div>

        {/* --- MIDDLE SECTION: STOCK & ALERTS --- */}
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
          {/* Stock Movement Mini-Table */}
          <div className="lg:col-span-2 space-y-5">
            <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-2 border-b-2 border-slate-300 pb-3">
              <h3 className="text-sm font-black uppercase tracking-widest text-slate-800">Inventory Levels (Physical)</h3>
              <span className="text-[10px] font-bold text-slate-400 uppercase tracking-normal">Latest System Computation</span>
            </div>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
              <InventoryMiniCards />
            </div>
          </div>

          {/* Alerts & Audit Summary */}
          <div className="space-y-5">
            <div className="border border-slate-300 bg-white p-5 space-y-4">
              <h3 className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-500 border-b-2 border-slate-200 pb-3">Audit Trail (Recent)</h3>
              <div className="space-y-1">
                <RecentTransactionsFeed />
              </div>

              <Button
                variant="outline"
                className="w-full rounded-none border-slate-300 font-bold uppercase text-[10px] tracking-widest h-10 mt-2"
                onClick={() => navigate('/manage-transactions')}
              >
                <ShieldCheck className="h-3.5 w-3.5 mr-2" /> Open Audit System
              </Button>
            </div>

            <div className="bg-white border border-slate-200 p-5 flex flex-col sm:flex-row sm:justify-between sm:items-center gap-3">
              <div className="flex flex-col gap-0.5">
                <span className="text-[9px] font-black uppercase text-slate-500 tracking-widest">Net Market Position</span>
                <span className={cn("text-xs font-bold", dashboardMarket.market_balance >= 0 ? "text-emerald-700" : "text-rose-700")}>
                  {dashboardMarket.market_balance >= 0 ? "Dr (Net Asset)" : "Cr (Net Liability)"}
                </span>
              </div>
              <span className="text-2xl font-black text-slate-900 num-audit tracking-tight break-words">{formatPKR(Math.abs(dashboardMarket.market_balance))}</span>
            </div>
          </div>
        </div>
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

  return inventory?.map((item: any, i: number) => (
    <div key={i} className="border border-slate-300 bg-white p-5 flex flex-col justify-between hover:bg-slate-50/50">
      <div className="flex items-center justify-between mb-3">
        <span className="text-[10px] font-black uppercase text-slate-500 tracking-widest">{item.fuel_name}</span>
        <div className={`h-2.5 w-2.5 ${item.closing_stock > 1000 ? "bg-emerald-500" : "bg-rose-500"}`}></div>
      </div>

      <div className="mb-1">
        <h4 className="text-3xl font-black text-slate-900 num-audit leading-none tracking-tight">
          {formatNumber(item.closing_stock)}
          <span className="text-[10px] ml-1.5 text-slate-400 font-bold uppercase">Ltr</span>
        </h4>
      </div>

      <div className="mt-3 pt-3 border-t border-slate-200 grid grid-cols-2 gap-2">
        <div className="flex flex-col gap-0.5">
          <span className="text-[8px] font-black text-slate-400 uppercase">Purchased</span>
          <span className="text-xs font-black text-emerald-700 num-audit">+{formatNumber(item.purchased)}</span>
        </div>
        <div className="flex flex-col items-end gap-0.5">
          <span className="text-[8px] font-black text-slate-400 uppercase">Sold</span>
          <span className="text-xs font-black text-rose-700 num-audit">-{formatNumber(item.sold)}</span>
        </div>
      </div>
    </div>
  ));
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


    let colorClass = "bg-slate-50 text-slate-500 border-slate-200";
    if (isSale) colorClass = "bg-emerald-50 text-emerald-700 border-emerald-200";
    if (isPurchase) colorClass = "bg-rose-50 text-rose-700 border-rose-200";
    if (isPayment) colorClass = "bg-blue-50 text-blue-700 border-blue-200";
    if (isReversal) colorClass = "bg-amber-50 text-amber-700 border-amber-200";



    return (
      <div key={idx} className="flex items-center justify-between py-2.5 border-b border-slate-100 last:border-0 hover:bg-slate-50/50 px-2">
        <div className="flex flex-col gap-0.5 min-w-0">
          <div className="flex items-center gap-2">
            <span className={cn("text-[7px] font-black uppercase px-1.5 py-0.5 border leading-none", colorClass)}>
              {item.display_type}
            </span>
            <span className="text-[10px] font-bold text-slate-900 truncate max-w-[150px] uppercase">
              {item.party?.name || 'Party'}
            </span>
          </div>
          <span className="text-[9px] text-slate-400 font-medium truncate italic pl-0.5" title={item.clean_narration}>
            {item.clean_narration || 'No remarks'}
          </span>
        </div>
        <div className="text-right flex flex-col items-end gap-0.5 flex-shrink-0 ml-3">
          <span className="text-[11px] font-black text-slate-900 num-audit">
            {formatPKR(item.amount).replace('Rs. ', '')}
          </span>
          <span className="text-[8px] font-medium text-slate-400 uppercase num-audit">
            {new Date(item.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
          </span>
        </div>
      </div>
    );
  });
}
