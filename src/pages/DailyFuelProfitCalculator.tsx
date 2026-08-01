import { useEffect, useMemo, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { AlertTriangle, Calculator, CheckCircle2, ClipboardCheck, Database, History, Loader2, RefreshCw, Save, ShieldCheck, Calendar } from 'lucide-react';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { useToast } from '@/hooks/use-toast';
import { formatDate, formatNumber, formatPKR } from '@/lib/format';
import { supabase } from '@/integrations/supabase/client';
import { cn } from '@/lib/utils';

type SourceLine = {
  fuel_type_id: string;
  fuel_name: string;
  quantity: number;
  actual_revenue: number;
  effective_sale_rate: number;
  source_sales_fingerprint: string;
  source_sale_count: number;
};

type PnLRow = { section_name: string; amount: number };
type OfficialFuelLine = SourceLine & { cogs: number; grossProfit: number };

const isoToday = () => new Date().toISOString().slice(0, 10);
const number = (value: unknown) => Number(value) || 0;

export default function DailyFuelProfitCalculator() {
  const [date, setDate] = useState(isoToday());
  const [activeTab, setActiveTab] = useState('official');
  const [manualRates, setManualRates] = useState<Record<string, string>>({});
  const [notes, setNotes] = useState('');
  const [saveAsRevisionOf, setSaveAsRevisionOf] = useState<string | null>(null);
  const { toast } = useToast();
  const queryClient = useQueryClient();
  const db = supabase as any;

  const sourceQuery = useQuery<SourceLine[]>({
    queryKey: ['commercial-profit-source', date],
    queryFn: async () => {
      const { data, error } = await db.rpc('get_commercial_profit_source', { p_date: date });
      if (error) throw error;
      return (data || []).map((row: any) => ({ ...row, quantity: number(row.quantity), actual_revenue: number(row.actual_revenue), effective_sale_rate: number(row.effective_sale_rate) }));
    },
  });

  useEffect(() => {
    if (!sourceQuery.data) return;
    setManualRates(current => Object.fromEntries(sourceQuery.data!.map(line => [line.fuel_type_id, current[line.fuel_type_id] ?? ''])));
  }, [sourceQuery.data]);

  const officialQuery = useQuery({
    queryKey: ['official-daily-profit', date],
    queryFn: async () => {
      const [pnlResult, salesResult, ledgerResult] = await Promise.all([
        db.rpc('get_profit_loss_v13', { p_start_date: date, p_end_date: date }),
        db.from('sales').select('voucher_no, fuel_type_id, quantity, total_amount, fuel_types(name)').eq('sale_date', date).eq('is_reversed', false),
        db.from('ledger_entries').select('voucher_no, debit_amount, credit_amount, accounts!inner(code, slug)').eq('posting_date', date).eq('is_reversed', false),
      ]);
      if (pnlResult.error) throw pnlResult.error;
      if (salesResult.error) throw salesResult.error;
      if (ledgerResult.error) throw ledgerResult.error;

      const pnl = (pnlResult.data || []) as PnLRow[];
      const revenue = pnl.filter(row => row.section_name === 'Revenue').reduce((sum, row) => sum + number(row.amount), 0);
      const cogs = pnl.filter(row => row.section_name === 'Cost of Sales').reduce((sum, row) => sum + number(row.amount), 0);
      const expenses = pnl.filter(row => !['Revenue', 'Cost of Sales'].includes(row.section_name)).reduce((sum, row) => sum + number(row.amount), 0);
      const cogsByVoucher = new Map<string, number>();
      (ledgerResult.data || []).forEach((entry: any) => {
        const account = Array.isArray(entry.accounts) ? entry.accounts[0] : entry.accounts;
        if (account?.code === '4100' || account?.slug === 'cogs') {
          cogsByVoucher.set(entry.voucher_no, (cogsByVoucher.get(entry.voucher_no) || 0) + number(entry.debit_amount) - number(entry.credit_amount));
        }
      });
      const byFuel = new Map<string, OfficialFuelLine>();
      (salesResult.data || []).forEach((sale: any) => {
        const fuel = Array.isArray(sale.fuel_types) ? sale.fuel_types[0] : sale.fuel_types;
        const existing = byFuel.get(sale.fuel_type_id) || {
          fuel_type_id: sale.fuel_type_id, fuel_name: fuel?.name || 'Unknown fuel', quantity: 0,
          actual_revenue: 0, effective_sale_rate: 0, source_sales_fingerprint: '', source_sale_count: 0, cogs: 0, grossProfit: 0,
        };
        existing.quantity += number(sale.quantity);
        existing.actual_revenue += number(sale.total_amount);
        existing.cogs += cogsByVoucher.get(sale.voucher_no) || 0;
        existing.source_sale_count += 1;
        existing.effective_sale_rate = existing.actual_revenue / (existing.quantity || 1);
        existing.grossProfit = existing.actual_revenue - existing.cogs;
        byFuel.set(sale.fuel_type_id, existing);
      });
      const linkedCogs = [...byFuel.values()].reduce((sum, row) => sum + row.cogs, 0);
      return { revenue, cogs, expenses, grossProfit: revenue - cogs, netProfit: revenue - cogs - expenses, lines: [...byFuel.values()], linkedCogs, unallocatedCogs: cogs - linkedCogs };
    },
  });

  const historyQuery = useQuery({
    queryKey: ['commercial-profit-history', date],
    queryFn: async () => {
      const { data, error } = await db
        .from('commercial_profit_calculations')
        .select('id, calculation_date, version_no, status, notes, source_sales_fingerprint, source_sale_count, created_at, void_reason, commercial_profit_calculation_lines(*)')
        .eq('calculation_date', date)
        .order('version_no', { ascending: false });
      if (error) throw error;
      return data || [];
    },
  });

  const totals = useMemo(() => (sourceQuery.data || []).reduce((result, line) => {
    const rate = number(manualRates[line.fuel_type_id]);
    const estimatedCost = line.quantity * rate;
    result.quantity += line.quantity;
    result.revenue += line.actual_revenue;
    result.cost += estimatedCost;
    result.profit += line.actual_revenue - estimatedCost;
    return result;
  }, { quantity: 0, revenue: 0, cost: 0, profit: 0 }), [sourceQuery.data, manualRates]);

  const saveMutation = useMutation({
    mutationFn: async () => {
      const lines = sourceQuery.data || [];
      if (!lines.length) throw new Error('No active sales are available for this date.');
      if (lines.some(line => manualRates[line.fuel_type_id] === '' || number(manualRates[line.fuel_type_id]) < 0)) {
        throw new Error('Enter a valid manual cost rate for every fuel before saving.');
      }
      const { error } = await db.rpc('save_commercial_profit_calculation', {
        p_date: date,
        p_manual_lines: lines.map(line => ({ fuel_type_id: line.fuel_type_id, manual_cost_rate: number(manualRates[line.fuel_type_id]) })),
        p_notes: notes || null,
        p_supersedes_id: saveAsRevisionOf,
      });
      if (error) throw error;
    },
    onSuccess: () => {
      toast({ title: 'Commercial calculation saved', description: 'A separate, versioned estimate snapshot was created. Official accounting was not changed.' });
      setNotes('');
      setSaveAsRevisionOf(null);
      queryClient.invalidateQueries({ queryKey: ['commercial-profit-history', date] });
    },
    onError: (error: Error) => toast({ variant: 'destructive', title: 'Could not save calculation', description: error.message }),
  });

  // ── Commercial Period Summary States ──────────────────────
  const [periodStartDate, setPeriodStartDate] = useState(() => {
    const today = new Date();
    return new Date(today.getFullYear(), today.getMonth(), 1).toISOString().slice(0, 10);
  });
  const [periodEndDate, setPeriodEndDate] = useState(() => isoToday());
  const [isPeriodClosed, setIsPeriodClosed] = useState(false);

  useEffect(() => {
    setIsPeriodClosed(false);
  }, [periodStartDate, periodEndDate]);

  // Query 1: Calculations in range
  const periodCalcsQuery = useQuery({
    queryKey: ['commercial-period-calculations', periodStartDate, periodEndDate],
    queryFn: async () => {
      const { data, error } = await db
        .from('commercial_profit_calculations')
        .select('id, calculation_date, status, version_no, commercial_profit_calculation_lines(quantity, actual_revenue, estimated_cost, commercial_profit)')
        .gte('calculation_date', periodStartDate)
        .lte('calculation_date', periodEndDate);
      if (error) throw error;
      return data || [];
    },
    enabled: activeTab === 'summary'
  });

  // Query 2: Sales in range
  const periodSalesQuery = useQuery({
    queryKey: ['commercial-period-sales', periodStartDate, periodEndDate],
    queryFn: async () => {
      const { data, error } = await db
        .from('sales')
        .select('sale_date, total_amount')
        .eq('is_reversed', false)
        .gte('sale_date', periodStartDate)
        .lte('sale_date', periodEndDate);
      if (error) throw error;
      return data || [];
    },
    enabled: activeTab === 'summary'
  });

  // Query 3: Shrinkage in range
  const periodShrinkageQuery = useQuery({
    queryKey: ['commercial-period-shrinkage', periodStartDate, periodEndDate],
    queryFn: async () => {
      const [qtyRes, amtRes] = await Promise.all([
        db
          .from('inventory_events')
          .select('quantity, created_at')
          .like('voucher_no', 'SHR-%')
          .gte('created_at', `${periodStartDate}T00:00:00Z`)
          .lte('created_at', `${periodEndDate}T23:59:59.999Z`),
        db
          .from('ledger_entries')
          .select('debit_amount, credit_amount, accounts!inner(code)')
          .eq('accounts.code', '5000')
          .eq('is_reversed', false)
          .gte('posting_date', periodStartDate)
          .lte('posting_date', periodEndDate)
      ]);
      
      if (qtyRes.error) throw qtyRes.error;
      if (amtRes.error) throw amtRes.error;
      
      const qtySum = (qtyRes.data || []).reduce((sum: number, ie: any) => sum + Math.abs(number(ie.quantity)), 0);
      const amtSum = (amtRes.data || []).reduce((sum: number, le: any) => sum + (number(le.debit_amount) - number(le.credit_amount)), 0);
      
      return { quantity: qtySum, amount: amtSum };
    },
    enabled: activeTab === 'summary'
  });

  // Process Period Summary
  const periodSummary = useMemo(() => {
    if (!periodCalcsQuery.data || !periodSalesQuery.data || !periodShrinkageQuery.data) return null;
    
    const calcs = periodCalcsQuery.data || [];
    const sales = periodSalesQuery.data || [];
    const shrinkage = periodShrinkageQuery.data || { quantity: 0, amount: 0 };

    const allCalcsByDate = new Map<string, any[]>();
    const reviewedCalcsByDate = new Map<string, any>();
    
    calcs.forEach((c: any) => {
      const d = c.calculation_date;
      if (!allCalcsByDate.has(d)) {
        allCalcsByDate.set(d, []);
      }
      allCalcsByDate.get(d)!.push(c);
      
      if (c.status === 'reviewed_snapshot') {
        const existing = reviewedCalcsByDate.get(d);
        if (!existing || c.version_no > existing.version_no) {
          reviewedCalcsByDate.set(d, c);
        }
      }
    });

    const salesByDate = new Map<string, { count: number; revenue: number }>();
    sales.forEach((s: any) => {
      const d = s.sale_date;
      const existing = salesByDate.get(d) || { count: 0, revenue: 0 };
      existing.count += 1;
      existing.revenue += number(s.total_amount);
      salesByDate.set(d, existing);
    });

    const datesList: string[] = [];
    const curr = new Date(periodStartDate);
    const end = new Date(periodEndDate);
    while (curr <= end) {
      datesList.push(curr.toISOString().split('T')[0]);
      curr.setDate(curr.getDate() + 1);
    }
    
    datesList.reverse();

    let totalRevenue = 0;
    let totalCost = 0;
    let totalGrossProfit = 0;
    let calculatedDaysCount = 0;
    
    const dailyRecords = datesList.map(date => {
      const dayCalcs = allCalcsByDate.get(date) || [];
      const salesInfo = salesByDate.get(date) || { count: 0, revenue: 0 };
      const reviewed = reviewedCalcsByDate.get(date);
      
      let status: 'Reviewed' | 'Missing' | 'Revised' | 'Superseded' | 'No Sales' = 'Missing';
      let statusCls = '';
      
      if (reviewed) {
        if (reviewed.version_no > 1) {
          status = 'Revised';
          statusCls = 'bg-indigo-50 text-indigo-700 border-indigo-200';
        } else {
          status = 'Reviewed';
          statusCls = 'bg-emerald-50 text-emerald-700 border-emerald-200';
        }
        
        const lines = reviewed.commercial_profit_calculation_lines || [];
        lines.forEach((l: any) => {
          totalRevenue += number(l.actual_revenue);
          totalCost += number(l.estimated_cost);
          totalGrossProfit += number(l.commercial_profit);
        });
        calculatedDaysCount += 1;
        
      } else if (salesInfo.count === 0) {
        status = 'No Sales';
        statusCls = 'bg-slate-100 text-slate-500 border-slate-200';
      } else {
        const hasSuperseded = dayCalcs.some(c => c.status === 'superseded');
        if (hasSuperseded) {
          status = 'Superseded';
          statusCls = 'bg-amber-50 text-amber-700 border-amber-200';
        } else {
          status = 'Missing';
          statusCls = 'bg-rose-50 text-rose-700 border-rose-200';
        }
      }
      
      return {
        date,
        saleCount: salesInfo.count,
        salesRevenue: salesInfo.revenue,
        status,
        statusCls,
        hasReviewed: !!reviewed
      };
    });

    const missingClosings = dailyRecords.filter(r => r.status === 'Missing');
    const missingClosingsCount = missingClosings.length;
    const commercialNetProfit = totalGrossProfit - shrinkage.amount;

    return {
      revenue: totalRevenue,
      cost: totalCost,
      grossProfit: totalGrossProfit,
      shrinkageQty: shrinkage.quantity,
      shrinkageAmt: shrinkage.amount,
      netProfit: commercialNetProfit,
      calculatedDays: calculatedDaysCount,
      missingClosingsCount,
      missingClosings,
      dailyRecords
    };
  }, [periodStartDate, periodEndDate, periodCalcsQuery.data, periodSalesQuery.data, periodShrinkageQuery.data]);

  const latestHistory = historyQuery.data?.[0];
  const sourceChanged = Boolean(latestHistory && (!sourceQuery.data?.length || latestHistory.source_sales_fingerprint !== sourceQuery.data[0].source_sales_fingerprint));

  return (
    <DashboardLayout>
      <main className="mx-auto max-w-7xl space-y-6 p-4 md:p-7">
        <section className="rounded-xl border border-slate-200 bg-gradient-to-br from-slate-950 via-slate-900 to-indigo-950 p-6 text-white shadow-sm">
          <div className="flex flex-col justify-between gap-5 lg:flex-row lg:items-end">
            <div>
              <div className="mb-3 flex items-center gap-2 text-xs font-black uppercase tracking-[0.2em] text-indigo-200"><Calculator className="h-4 w-4" /> Daily Profit</div>
              <h1 className="text-2xl font-black tracking-tight md:text-3xl">Accounting and management view</h1>

            </div>
            <label className="block text-xs font-bold uppercase tracking-wider text-slate-300">Calculation date
              <Input type="date" max={isoToday()} value={date} onChange={event => setDate(event.target.value)} className="mt-2 w-full border-slate-600 bg-white text-slate-950 lg:w-52" />
            </label>
          </div>
        </section>

        <Tabs value={activeTab} onValueChange={setActiveTab} className="space-y-5">
          <TabsList className="h-auto w-full justify-start gap-1 overflow-x-auto rounded-lg border border-slate-200 bg-white p-1.5">
            <TabsTrigger value="official" className="gap-2 px-4 py-2.5 text-xs font-black uppercase tracking-wide"><ShieldCheck className="h-4 w-4" /> Official Profit</TabsTrigger>
            <TabsTrigger value="commercial" className="gap-2 px-4 py-2.5 text-xs font-black uppercase tracking-wide"><Calculator className="h-4 w-4" /> Commercial Calculator</TabsTrigger>
            <TabsTrigger value="history" className="gap-2 px-4 py-2.5 text-xs font-black uppercase tracking-wide"><History className="h-4 w-4" /> Commercial History</TabsTrigger>
            <TabsTrigger value="summary" className="gap-2 px-4 py-2.5 text-xs font-black uppercase tracking-wide"><Calendar className="h-4 w-4" /> Period Summary</TabsTrigger>
          </TabsList>

          <TabsContent value="official" className="space-y-5">

            {officialQuery.isLoading ? <Loading /> : officialQuery.isError ? <ErrorMessage /> : !officialQuery.data?.lines.length ? (
              <div className="rounded-xl border border-dashed border-slate-300 bg-white p-10 text-center">
                <Database className="mx-auto h-8 w-8 text-slate-400" />
                <p className="mt-3 font-bold text-slate-700">No sales recorded for this date.</p>
                <p className="text-xs text-slate-500 mt-1">Select another date to view profit details.</p>
              </div>
            ) : (
              <>
                <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
                  <Metric label="Sales Revenue" value={formatPKR(officialQuery.data?.revenue)} />
                  <Metric label="Fuel Cost" value={formatPKR(officialQuery.data?.cogs)} subtitle="Based on AVCO" />
                  <Metric label="Gross Profit" value={formatPKR(officialQuery.data?.grossProfit)} positive />
                  <Metric label="Expenses" value={formatPKR(officialQuery.data?.expenses)} />
                  <Metric label="Net Profit" value={formatPKR(officialQuery.data?.netProfit)} positive />
                </div>
                <OfficialTable lines={officialQuery.data?.lines || []} unallocated={officialQuery.data?.unallocatedCogs || 0} />
              </>
            )}
          </TabsContent>

          <TabsContent value="commercial" className="space-y-5">
            <div className="flex justify-between items-center bg-white p-3 border rounded-xl shadow-sm">
              <h3 className="text-xs font-black uppercase tracking-widest text-slate-500">Manual Cost-Rate Entry</h3>
              <Button size="sm" variant="outline" onClick={() => sourceQuery.refetch()} disabled={sourceQuery.isFetching} className="border-slate-300"><RefreshCw className="mr-2 h-3.5 w-3.5" /> Refresh Sales</Button>
            </div>
            {sourceChanged && <div className="flex gap-3 rounded-lg border border-orange-300 bg-orange-50 p-4 text-sm text-orange-950"><AlertTriangle className="mt-0.5 h-5 w-5 shrink-0" /><div><strong>Source sales changed since the latest saved calculation.</strong> Create a revised version if you want to capture the current sales snapshot.</div></div>}
            {sourceQuery.isLoading ? <Loading /> : !sourceQuery.data?.length ? <EmptySales /> : <>
              <CommercialTable lines={sourceQuery.data} manualRates={manualRates} onRateChange={(id, value) => setManualRates(current => ({ ...current, [id]: value }))} />
              <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4"><Metric label="Sale volume" value={`${formatNumber(totals.quantity)} L`} /><Metric label="Actual revenue" value={formatPKR(totals.revenue)} /><Metric label="Estimated cost" value={formatPKR(totals.cost)} /><Metric label="Commercial gross profit" value={formatPKR(totals.profit)} positive /></div>
              <section className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
                <div className="mb-4 flex items-center gap-2"><Save className="h-4 w-4 text-indigo-600" /><h2 className="font-black text-slate-950">Save commercial calculation</h2></div>
                {saveAsRevisionOf && <div className="mb-3 rounded-md bg-indigo-50 p-3 text-sm text-indigo-950">Saving a new revision of the selected snapshot. The prior snapshot will remain in history as Superseded.</div>}
                <Textarea value={notes} onChange={event => setNotes(event.target.value)} placeholder="Optional notes: supplier context, market assumption, or reason for revision" className="min-h-20" />
                <div className="mt-4 flex flex-wrap items-center gap-3"><Button onClick={() => saveMutation.mutate()} disabled={saveMutation.isPending}><Save className="mr-2 h-4 w-4" /> {saveMutation.isPending ? 'Saving…' : saveAsRevisionOf ? 'Save revised snapshot' : 'Save commercial calculation'}</Button><span className="text-xs text-slate-500">No auto-save. Saved figures are permanent snapshots.</span></div>
              </section>
            </>}
          </TabsContent>

          <TabsContent value="history" className="space-y-4">

            {historyQuery.isLoading ? <Loading /> : !historyQuery.data?.length ? <div className="rounded-xl border border-dashed border-slate-300 bg-white p-10 text-center text-sm text-slate-500">No commercial calculation has been saved for {formatDate(date)}.</div> : historyQuery.data.map((record: any) => {
              const lines = record.commercial_profit_calculation_lines || [];
              const revenue = lines.reduce((sum: number, line: any) => sum + number(line.actual_revenue), 0);
              const profit = lines.reduce((sum: number, line: any) => sum + number(line.commercial_profit), 0);
              return <section key={record.id} className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm"><div className="flex flex-col justify-between gap-3 sm:flex-row"><div><div className="flex items-center gap-2"><h2 className="font-black text-slate-950">Version {record.version_no}</h2><StatusBadge status={record.status} /></div><p className="mt-1 text-xs text-slate-500">Saved {formatDate(record.created_at)} · {record.source_sale_count} source sales</p></div><div className="text-left sm:text-right"><p className="text-xs font-bold uppercase tracking-wider text-slate-500">Commercial profit</p><p className="text-lg font-black text-emerald-700">{formatPKR(profit)}</p></div></div>{record.notes && <p className="mt-3 rounded bg-slate-50 p-3 text-sm text-slate-600">{record.notes}</p>}<div className="mt-4 overflow-x-auto"><table className="min-w-full text-sm"><thead className="border-b text-left text-xs uppercase tracking-wider text-slate-500"><tr><th className="pb-2">Fuel</th><th className="pb-2 text-right">Qty</th><th className="pb-2 text-right">Revenue</th><th className="pb-2 text-right">Sale Price/L</th><th className="pb-2 text-right">Manual cost/L</th><th className="pb-2 text-right">Profit</th></tr></thead><tbody>{lines.map((line: any) => <tr key={line.id} className="border-b last:border-0"><td className="py-2 font-semibold">{line.fuel_name_snapshot}</td><td className="py-2 text-right">{formatNumber(number(line.quantity))} L</td><td className="py-2 text-right">{formatPKR(number(line.actual_revenue))}</td><td className="py-2 text-right">{formatPKR(number(line.effective_sale_rate))}</td><td className="py-2 text-right">{formatPKR(number(line.manual_cost_rate))}</td><td className="py-2 text-right font-bold">{formatPKR(number(line.commercial_profit))}</td></tr>)}</tbody></table></div>{record.status === 'reviewed_snapshot' && <Button variant="outline" size="sm" className="mt-4" onClick={() => { setSaveAsRevisionOf(record.id); setActiveTab('commercial'); }}><ClipboardCheck className="mr-2 h-4 w-4" /> Create revised version</Button>}</section>;
            })}
          </TabsContent>

          <TabsContent value="summary" className="space-y-5">
            {/* Disclaimer Note */}
            <div className="rounded-xl border border-indigo-150 bg-indigo-50/40 p-4 text-xs text-indigo-900 flex items-start gap-3 shadow-xs">
              <ShieldCheck className="h-5 w-5 text-indigo-600 shrink-0 mt-0.5" />
              <div>
                <span className="font-bold uppercase tracking-wider block mb-0.5">Management Estimation Notice</span>
                Commercial profit is a management estimate based on reviewed manual cost rates. Official accounting profit remains AVCO-based.
              </div>
            </div>

            {/* Date Filters & Close Guard Box */}
            <div className="flex flex-col xl:flex-row gap-4 items-start xl:items-stretch">
              {/* Date Filters Card */}
              <div className="flex-1 rounded-xl border border-slate-200 bg-white p-5 shadow-sm space-y-4">
                <div className="flex items-center gap-2 text-xs font-black uppercase tracking-wider text-slate-500">
                  <Calendar className="h-4 w-4" /> Period Date Filters
                </div>
                <div className="flex flex-wrap items-center gap-4">
                  <label className="block text-xs font-bold uppercase tracking-wider text-slate-600">Start Date
                    <Input type="date" max={isoToday()} value={periodStartDate} onChange={event => setPeriodStartDate(event.target.value)} className="mt-2 w-full max-w-xs" />
                  </label>
                  <label className="block text-xs font-bold uppercase tracking-wider text-slate-600">End Date
                    <Input type="date" max={isoToday()} value={periodEndDate} onChange={event => setPeriodEndDate(event.target.value)} className="mt-2 w-full max-w-xs" />
                  </label>
                </div>
              </div>

              {/* Close Guard Card */}
              <div className="w-full xl:w-96 rounded-xl border border-slate-200 bg-white p-5 shadow-sm flex flex-col justify-between">
                <div>
                  <div className="flex items-center justify-between">
                    <h3 className="font-black text-slate-900 text-sm">Period Commercial Close</h3>
                    {(!periodSummary || periodSummary.missingClosingsCount > 0) ? (
                      <span className="inline-flex items-center gap-1 text-[10px] font-bold uppercase tracking-wide text-rose-600 bg-rose-50 border border-rose-100 px-2 py-0.5 rounded-full">
                        Pending
                      </span>
                    ) : (
                      <span className="inline-flex items-center gap-1 text-[10px] font-bold uppercase tracking-wide text-emerald-600 bg-emerald-50 border border-emerald-100 px-2 py-0.5 rounded-full">
                        Ready
                      </span>
                    )}
                  </div>
                  <p className="text-xs text-slate-500 mt-2 leading-relaxed">
                    Completion is guarded. All active sales dates in this range must contain a reviewed commercial estimate first.
                  </p>
                </div>
                <div className="mt-4 pt-3 border-t border-slate-100">
                  <Button 
                    className="w-full"
                    disabled={!periodSummary || periodSummary.missingClosingsCount > 0 || isPeriodClosed}
                    onClick={() => {
                      setIsPeriodClosed(true);
                      toast({
                        title: "Commercial Period Marked Complete",
                        description: "The selected date range has been successfully completed."
                      });
                    }}
                  >
                    {isPeriodClosed ? 'Period Marked Complete' : 'Mark Period Complete'}
                  </Button>
                </div>
              </div>
            </div>

            {/* Warning Banner */}
            {periodSummary && periodSummary.missingClosingsCount > 0 && (
              <div className="rounded-xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-950 flex flex-col md:flex-row md:items-center justify-between gap-3 shadow-xs">
                <div className="flex gap-2.5">
                  <AlertTriangle className="h-5 w-5 text-rose-600 shrink-0 mt-0.5" />
                  <div>
                    <span className="font-bold">{periodSummary.missingClosingsCount} commercial profit closings are pending.</span>
                    <p className="text-xs text-rose-800 mt-1 leading-relaxed">
                      Pending dates: {periodSummary.missingClosings.slice().reverse().slice(0, 5).map(r => formatDate(r.date)).join(', ')}
                      {periodSummary.missingClosingsCount > 5 && ` and ${periodSummary.missingClosingsCount - 5} more.`}
                    </p>
                  </div>
                </div>
                <Button 
                  size="sm" 
                  variant="destructive"
                  onClick={() => {
                    const firstMissingDate = periodSummary.missingClosings[periodSummary.missingClosings.length - 1].date;
                    setDate(firstMissingDate);
                    setActiveTab('commercial');
                  }}
                >
                  Complete Missing Closings
                </Button>
              </div>
            )}

            {/* Summary Cards */}
            {(!periodSummary || periodCalcsQuery.isLoading || periodSalesQuery.isLoading || periodShrinkageQuery.isLoading) ? (
              <Loading />
            ) : (
              <>
                <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                  <Metric label="Commercial Revenue" value={formatPKR(periodSummary.revenue)} />
                  <Metric label="Commercial Cost" value={formatPKR(periodSummary.cost)} />
                  <Metric label="Commercial Gross Profit" value={formatPKR(periodSummary.grossProfit)} positive />
                  <Metric label="Commercial Net Profit" value={formatPKR(periodSummary.netProfit)} positive />
                  <Metric label="Fuel Shrinkage Qty" value={`${formatNumber(periodSummary.shrinkageQty)} L`} />
                  <Metric label="Fuel Shrinkage Amt" value={formatPKR(periodSummary.shrinkageAmt)} />
                  <Metric label="Calculated Days" value={`${periodSummary.calculatedDays} days`} />
                  <Metric label="Missing Closings" value={`${periodSummary.missingClosingsCount} days`} />
                </div>

                {/* Split Layout for Reconciliation & Daily Records */}
                <div className="grid gap-6 lg:grid-cols-3">
                  {/* Reconciliation Column */}
                  <div className="lg:col-span-1">
                    <section className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm space-y-4">
                      <h2 className="font-black text-slate-900 text-xs uppercase tracking-wider">Commercial Reconciliation</h2>
                      <div className="divide-y divide-slate-100 text-sm">
                        <div className="flex justify-between py-2.5">
                          <span className="text-slate-600">Commercial Gross Profit</span>
                          <span className="font-bold text-slate-900">{formatPKR(periodSummary.grossProfit)}</span>
                        </div>
                        <div className="flex justify-between py-2.5 text-rose-600">
                          <span className="font-medium">Less: Fuel Shrinkage</span>
                          <span className="font-bold">({formatPKR(periodSummary.shrinkageAmt)})</span>
                        </div>
                        <div className="flex justify-between py-3 font-black text-emerald-700 bg-emerald-50/30 px-2 rounded mt-1">
                          <span>Commercial Net Profit</span>
                          <span className="text-base">{formatPKR(periodSummary.netProfit)}</span>
                        </div>
                      </div>
                    </section>
                  </div>

                  {/* Daily Records Column */}
                  <div className="lg:col-span-2">
                    <section className="overflow-hidden rounded-xl border border-slate-200 bg-white shadow-sm">
                      <div className="border-b p-5 flex items-center justify-between">
                        <h2 className="font-black text-slate-950 text-sm uppercase tracking-wider">Daily Records & Status</h2>
                        <span className="text-xs text-slate-500">{periodSummary.dailyRecords.length} total days</span>
                      </div>
                      <div className="overflow-x-auto max-h-[500px]">
                        <table className="min-w-full text-sm">
                          <thead className="bg-slate-50 text-left text-[10px] font-black uppercase tracking-wider text-slate-500 sticky top-0">
                            <tr>
                              <th className="p-4">Date</th>
                              <th className="p-4 text-right">Sale Count</th>
                              <th className="p-4 text-right">Sales Revenue</th>
                              <th className="p-4 text-center">Status</th>
                              <th className="p-4 text-right print:hidden">Calculate</th>
                            </tr>
                          </thead>
                          <tbody className="divide-y divide-slate-100">
                            {periodSummary.dailyRecords.map(record => (
                              <tr key={record.date} className="hover:bg-slate-50/50">
                                <td className="p-4 font-semibold text-slate-900">{formatDate(record.date)}</td>
                                <td className="p-4 text-right tabular-nums">{record.saleCount}</td>
                                <td className="p-4 text-right tabular-nums">{formatPKR(record.salesRevenue)}</td>
                                <td className="p-4 text-center">
                                  <span className={cn(
                                    "rounded-full px-2 py-0.5 text-[10px] font-black uppercase tracking-wide border shadow-xs",
                                    record.statusCls
                                  )}>
                                    {record.status}
                                  </span>
                                </td>
                                <td className="p-4 text-right print:hidden">
                                  <Button 
                                    size="sm" 
                                    variant="outline" 
                                    className="h-7 text-xs border-slate-300"
                                    onClick={() => {
                                      setDate(record.date);
                                      setActiveTab('commercial');
                                    }}
                                  >
                                    {record.hasReviewed ? 'Re-calculate' : 'Calculate'}
                                  </Button>
                                </td>
                              </tr>
                            ))}
                          </tbody>
                        </table>
                      </div>
                    </section>
                  </div>
                </div>
              </>
            )}
          </TabsContent>
        </Tabs>
      </main>
    </DashboardLayout>
  );
}

function Metric({ label, value, positive, subtitle }: { label: string; value: string; positive?: boolean; subtitle?: string }) { return <div className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-[10px] font-black uppercase tracking-[0.12em] text-slate-500">{label}</p><p className={`mt-2 text-xl font-black ${positive ? 'text-emerald-700' : 'text-slate-950'}`}>{value}</p>{subtitle && <p className="mt-1 text-[10px] text-slate-400 font-semibold uppercase tracking-wider">{subtitle}</p>}</div>; }
function Loading() { return <div className="flex min-h-48 items-center justify-center gap-2 text-sm text-slate-500"><Loader2 className="h-5 w-5 animate-spin" /> Loading data…</div>; }
function ErrorMessage() { return <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-800">Could not load the calculation data.</div>; }
function EmptySales() { return <div className="rounded-xl border border-dashed border-slate-300 bg-white p-10 text-center"><Database className="mx-auto h-8 w-8 text-slate-400" /><p className="mt-3 font-bold text-slate-700">No active sales</p></div>; }
function StatusBadge({ status }: { status: string }) { const map: Record<string, string> = { reviewed_snapshot: 'bg-emerald-100 text-emerald-800', superseded: 'bg-slate-100 text-slate-600', voided: 'bg-red-100 text-red-800' }; return <span className={`rounded-full px-2 py-1 text-[10px] font-black uppercase tracking-wide ${map[status] || map.reviewed_snapshot}`}>{status.replace('_', ' ')}</span>; }
function OfficialTable({ lines, unallocated }: { lines: OfficialFuelLine[]; unallocated: number }) { return <section className="overflow-hidden rounded-xl border border-slate-200 bg-white shadow-sm"><div className="border-b p-5"><h2 className="font-black text-slate-950">Profit by Fuel</h2></div><div className="overflow-x-auto"><table className="min-w-full text-sm"><thead className="bg-slate-50 text-left text-[10px] font-black uppercase tracking-wider text-slate-500"><tr><th className="p-4">Fuel</th><th className="p-4 text-right">Quantity</th><th className="p-4 text-right">Sales</th><th className="p-4 text-right">Fuel Cost</th><th className="p-4 text-right">Profit</th></tr></thead><tbody>{lines.map(line => <tr key={line.fuel_type_id} className="border-t"><td className="p-4 font-bold text-slate-900">{line.fuel_name}</td><td className="p-4 text-right">{formatNumber(line.quantity)} L</td><td className="p-4 text-right">{formatPKR(line.actual_revenue)}</td><td className="p-4 text-right">{formatPKR(line.cogs)}</td><td className="p-4 text-right font-black text-emerald-700">{formatPKR(line.grossProfit)}</td></tr>)}</tbody></table></div>{Math.abs(unallocated) > 0.01 && <div className="flex gap-2 border-t border-orange-200 bg-orange-50 p-4 text-sm text-orange-900"><AlertTriangle className="h-5 w-5 shrink-0" />Unallocated COGS: {formatPKR(unallocated)}.</div>}</section>; }
function CommercialTable({ lines, manualRates, onRateChange }: { lines: SourceLine[]; manualRates: Record<string, string>; onRateChange: (id: string, value: string) => void }) { return <section className="overflow-hidden rounded-xl border border-slate-200 bg-white shadow-sm"><div className="border-b p-5"><h2 className="font-black text-slate-950">Manual rate estimate</h2></div><div className="overflow-x-auto"><table className="min-w-[900px] w-full text-sm"><thead className="bg-slate-50 text-left text-[10px] font-black uppercase tracking-wider text-slate-500"><tr><th className="p-4">Fuel</th><th className="p-4 text-right">Qty</th><th className="p-4 text-right">Actual revenue</th><th className="p-4 text-right">Effective sale/L</th><th className="p-4 text-right">Manual cost/L</th><th className="p-4 text-right">Estimate profit</th></tr></thead><tbody>{lines.map(line => { const costRate = number(manualRates[line.fuel_type_id]); const profit = line.actual_revenue - line.quantity * costRate; return <tr key={line.fuel_type_id} className="border-t"><td className="p-4 font-bold text-slate-900">{line.fuel_name}</td><td className="p-4 text-right">{formatNumber(line.quantity)} L</td><td className="p-4 text-right">{formatPKR(line.actual_revenue)}</td><td className="p-4 text-right">{formatPKR(line.effective_sale_rate)}</td><td className="p-3"><Input aria-label={`Manual cost rate for ${line.fuel_name}`} type="number" min="0" step="0.000001" value={manualRates[line.fuel_type_id] ?? ''} onChange={event => onRateChange(line.fuel_type_id, event.target.value)} className="ml-auto w-32 text-right" /></td><td className="p-4 text-right font-black text-emerald-700">{formatPKR(profit)}</td></tr>; })}</tbody></table></div></section>; }
