import { useEffect, useMemo, useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { AlertTriangle, Calculator, CheckCircle2, ClipboardCheck, Database, History, Loader2, RefreshCw, Save, ShieldCheck } from 'lucide-react';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { useToast } from '@/hooks/use-toast';
import { formatDate, formatNumber, formatPKR } from '@/lib/format';
import { supabase } from '@/integrations/supabase/client';

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

  const latestHistory = historyQuery.data?.[0];
  const sourceChanged = Boolean(latestHistory && (!sourceQuery.data?.length || latestHistory.source_sales_fingerprint !== sourceQuery.data[0].source_sales_fingerprint));

  return (
    <DashboardLayout>
      <main className="mx-auto max-w-7xl space-y-6 p-4 md:p-7">
        <section className="rounded-xl border border-slate-200 bg-gradient-to-br from-slate-950 via-slate-900 to-indigo-950 p-6 text-white shadow-sm">
          <div className="flex flex-col justify-between gap-5 lg:flex-row lg:items-end">
            <div>
              <div className="mb-3 flex items-center gap-2 text-xs font-black uppercase tracking-[0.2em] text-indigo-200"><Calculator className="h-4 w-4" /> Daily Fuel Profit</div>
              <h1 className="text-2xl font-black tracking-tight md:text-3xl">Official accounting & commercial estimate</h1>

            </div>
            <label className="block text-xs font-bold uppercase tracking-wider text-slate-300">Calculation date
              <Input type="date" max={isoToday()} value={date} onChange={event => setDate(event.target.value)} className="mt-2 w-full border-slate-600 bg-white text-slate-950 lg:w-52" />
            </label>
          </div>
        </section>

        <Tabs value={activeTab} onValueChange={setActiveTab} className="space-y-5">
          <TabsList className="h-auto w-full justify-start gap-1 overflow-x-auto rounded-lg border border-slate-200 bg-white p-1.5">
            <TabsTrigger value="official" className="gap-2 px-4 py-2.5 text-xs font-black uppercase tracking-wide"><ShieldCheck className="h-4 w-4" /> Official daily profit</TabsTrigger>
            <TabsTrigger value="commercial" className="gap-2 px-4 py-2.5 text-xs font-black uppercase tracking-wide"><Calculator className="h-4 w-4" /> Commercial calculator</TabsTrigger>
            <TabsTrigger value="history" className="gap-2 px-4 py-2.5 text-xs font-black uppercase tracking-wide"><History className="h-4 w-4" /> Commercial history</TabsTrigger>
          </TabsList>

          <TabsContent value="official" className="space-y-5">

            {officialQuery.isLoading ? <Loading /> : officialQuery.isError ? <ErrorMessage /> : (
              <>
                <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
                  <Metric label="Revenue" value={formatPKR(officialQuery.data?.revenue)} />
                  <Metric label="AVCO COGS" value={formatPKR(officialQuery.data?.cogs)} />
                  <Metric label="Gross profit" value={formatPKR(officialQuery.data?.grossProfit)} positive />
                  <Metric label="Recorded expenses" value={formatPKR(officialQuery.data?.expenses)} />
                  <Metric label="Profit after expenses" value={formatPKR(officialQuery.data?.netProfit)} positive />
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
        </Tabs>
      </main>
    </DashboardLayout>
  );
}

function Metric({ label, value, positive }: { label: string; value: string; positive?: boolean }) { return <div className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm"><p className="text-[10px] font-black uppercase tracking-[0.12em] text-slate-500">{label}</p><p className={`mt-2 text-xl font-black ${positive ? 'text-emerald-700' : 'text-slate-950'}`}>{value}</p></div>; }
function Loading() { return <div className="flex min-h-48 items-center justify-center gap-2 text-sm text-slate-500"><Loader2 className="h-5 w-5 animate-spin" /> Loading data…</div>; }
function ErrorMessage() { return <div className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-800">Could not load the calculation data.</div>; }
function EmptySales() { return <div className="rounded-xl border border-dashed border-slate-300 bg-white p-10 text-center"><Database className="mx-auto h-8 w-8 text-slate-400" /><p className="mt-3 font-bold text-slate-700">No active sales</p></div>; }
function StatusBadge({ status }: { status: string }) { const map: Record<string, string> = { reviewed_snapshot: 'bg-emerald-100 text-emerald-800', superseded: 'bg-slate-100 text-slate-600', voided: 'bg-red-100 text-red-800' }; return <span className={`rounded-full px-2 py-1 text-[10px] font-black uppercase tracking-wide ${map[status] || map.reviewed_snapshot}`}>{status.replace('_', ' ')}</span>; }
function OfficialTable({ lines, unallocated }: { lines: OfficialFuelLine[]; unallocated: number }) { return <section className="overflow-hidden rounded-xl border border-slate-200 bg-white shadow-sm"><div className="border-b p-5"><h2 className="font-black text-slate-950">Fuel-wise official gross profit</h2></div><div className="overflow-x-auto"><table className="min-w-full text-sm"><thead className="bg-slate-50 text-left text-[10px] font-black uppercase tracking-wider text-slate-500"><tr><th className="p-4">Fuel</th><th className="p-4 text-right">Quantity</th><th className="p-4 text-right">Revenue</th><th className="p-4 text-right">AVCO COGS</th><th className="p-4 text-right">Gross profit</th></tr></thead><tbody>{lines.map(line => <tr key={line.fuel_type_id} className="border-t"><td className="p-4 font-bold text-slate-900">{line.fuel_name}</td><td className="p-4 text-right">{formatNumber(line.quantity)} L</td><td className="p-4 text-right">{formatPKR(line.actual_revenue)}</td><td className="p-4 text-right">{formatPKR(line.cogs)}</td><td className="p-4 text-right font-black text-emerald-700">{formatPKR(line.grossProfit)}</td></tr>)}</tbody></table></div>{Math.abs(unallocated) > 0.01 && <div className="flex gap-2 border-t border-orange-200 bg-orange-50 p-4 text-sm text-orange-900"><AlertTriangle className="h-5 w-5 shrink-0" />Unallocated COGS: {formatPKR(unallocated)}.</div>}</section>; }
function CommercialTable({ lines, manualRates, onRateChange }: { lines: SourceLine[]; manualRates: Record<string, string>; onRateChange: (id: string, value: string) => void }) { return <section className="overflow-hidden rounded-xl border border-slate-200 bg-white shadow-sm"><div className="border-b p-5"><h2 className="font-black text-slate-950">Manual rate estimate</h2></div><div className="overflow-x-auto"><table className="min-w-[900px] w-full text-sm"><thead className="bg-slate-50 text-left text-[10px] font-black uppercase tracking-wider text-slate-500"><tr><th className="p-4">Fuel</th><th className="p-4 text-right">Qty</th><th className="p-4 text-right">Actual revenue</th><th className="p-4 text-right">Effective sale/L</th><th className="p-4 text-right">Manual cost/L</th><th className="p-4 text-right">Estimate profit</th></tr></thead><tbody>{lines.map(line => { const costRate = number(manualRates[line.fuel_type_id]); const profit = line.actual_revenue - line.quantity * costRate; return <tr key={line.fuel_type_id} className="border-t"><td className="p-4 font-bold text-slate-900">{line.fuel_name}</td><td className="p-4 text-right">{formatNumber(line.quantity)} L</td><td className="p-4 text-right">{formatPKR(line.actual_revenue)}</td><td className="p-4 text-right">{formatPKR(line.effective_sale_rate)}</td><td className="p-3"><Input aria-label={`Manual cost rate for ${line.fuel_name}`} type="number" min="0" step="0.000001" value={manualRates[line.fuel_type_id] ?? ''} onChange={event => onRateChange(line.fuel_type_id, event.target.value)} className="ml-auto w-32 text-right" /></td><td className="p-4 text-right font-black text-emerald-700">{formatPKR(profit)}</td></tr>; })}</tbody></table></div></section>; }
