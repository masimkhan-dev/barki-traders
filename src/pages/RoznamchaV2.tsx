// ============================================================
// RoznamchaV2.tsx — HARDENED TEST PAGE
// SAFE TO TEST: Original Roznamcha.tsx is NOT touched.
// Route: /roznamcha-v2
// ============================================================
// KEY FIXES APPLIED:
// 1. CASH_BANK_CODES constant → ['1000', '1010'] (correct codes)
// 2. Filter cash/bank rows FIRST → then group by voucher
// 3. mode classified via is_cash_tx flag (not debit===0&&credit===0)
// 4. INTERNAL_TRANSFER detected (both debit & credit > 0 on cash)
// 5. Totals = pure SUM(debit) + SUM(credit) — zero nominal logic
// 6. Reversed entries excluded from totals
// ============================================================

import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Button } from '@/components/ui/button';
import { supabase } from '@/integrations/supabase/client';
import { formatPKR } from '@/lib/format';
import {
    Loader2,
    ChevronLeft,
    ChevronRight,
    ShieldCheck,
    CheckCircle,
    Edit2,
    FlaskConical,
    BookOpen,
    ChevronDown,
} from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { useToast } from '@/hooks/use-toast';
import { useQueryClient, useMutation } from '@tanstack/react-query';
import { cn } from '@/lib/utils';

// ✅ RULE 1: Single source of truth for Cash/Bank account codes
// Update this array if a new bank/cash account is added to the chart of accounts
const CASH_BANK_CODES = ['1000', '1010'];

type TxMode = 'CASH/BANK' | 'INTERNAL_TRANSFER' | 'LEDGER_ONLY';

interface DailyTransactionV2 {
    id: string;
    raw_created_at: string;
    time: string;
    voucher_no: string;
    type: string;
    party_name: string;
    narration: string;
    debit: number;
    credit: number;
    reconciled: boolean;
    is_reversed: boolean;
    is_cash_tx: boolean;
    mode: TxMode;
    nominal_value: number; // Only used for LEDGER_ONLY display, never in totals
    fuel_name?: string;
    quantity?: number;
    rate_per_unit?: number;
    total_amount?: number;
}

function shortVoucherId(voucher_no: string): string {
    if (!voucher_no) return '#—';
    const parts = voucher_no.split('-');
    const last = parts[parts.length - 1];
    return last.length > 7 ? `${last.slice(-5)}` : `${last}`;
}

export default function RoznamchaV2() {
    const navigate = useNavigate();
    const queryClient = useQueryClient();
    const { toast } = useToast();
    const { role } = useAuth();
    const [selectedDate, setSelectedDate] = useState(new Date().toISOString().split('T')[0]);
    // ✅ NEW: Track which voucher row is expanded for ledger drill-down
    const [expandedVoucher, setExpandedVoucher] = useState<string | null>(null);

    const toggleExpand = (voucherNo: string) => {
        setExpandedVoucher(prev => prev === voucherNo ? null : voucherNo);
    };

    const { data: queryResult, isLoading } = useQuery({
        queryKey: ['roznamcha-v2', selectedDate],
        queryFn: async () => {
            const { data, error } = await supabase
                .from('ledger_entries')
                .select(`
          id,
          created_at,
          voucher_no,
          voucher_type,
          debit_amount,
          credit_amount,
          narration,
          reconciliation_status,
          is_reversed,
          accounts!inner(code, name),
          party:parties(name)
        `)
                .eq('posting_date', selectedDate)
                .order('created_at', { ascending: true })
                .order('voucher_no', { ascending: true });

            if (error) throw error;

            // Fetch fuel details for sale/purchase vouchers on this date
            const [salesRes, purchasesRes] = await Promise.all([
                supabase
                    .from('sales')
                    .select(`voucher_no, quantity, rate_per_unit, total_amount, fuel_types(name)`)
                    .eq('sale_date', selectedDate),
                supabase
                    .from('purchases')
                    .select(`voucher_no, quantity, rate_per_unit, total_amount, fuel_types(name)`)
                    .eq('purchase_date', selectedDate)
            ]);

            const fuelDetailMap = new Map<string, any>();
            (salesRes.data || []).forEach((s: any) => {
                fuelDetailMap.set(s.voucher_no, {
                    fuel_name: s.fuel_types?.name,
                    quantity: s.quantity,
                    rate_per_unit: s.rate_per_unit,
                    total_amount: s.total_amount
                });
            });
            (purchasesRes.data || []).forEach((p: any) => {
                fuelDetailMap.set(p.voucher_no, {
                    fuel_name: p.fuel_types?.name,
                    quantity: p.quantity,
                    rate_per_unit: p.rate_per_unit,
                    total_amount: p.total_amount
                });
            });

            const entries = (data || []) as any[];

            // ✅ RULE 2: Filter cash/bank rows FIRST
            // We need the full data for party names but we accumulate only cash rows
            const groupedMap = new Map<string, DailyTransactionV2>();

            entries.forEach((entry: any) => {
                const vNo = entry.voucher_no;
                const isCashOrBank = CASH_BANK_CODES.includes(entry.accounts?.code);

                if (!groupedMap.has(vNo)) {
                    // Initialize with first entry — cash values start at 0 unless this row is cash
                    groupedMap.set(vNo, {
                        id: entry.id,
                        raw_created_at: entry.created_at,
                        time: new Date(entry.created_at).toLocaleTimeString('en-PK', { hour: '2-digit', minute: '2-digit' }),
                        voucher_no: vNo,
                        type: entry.voucher_type,
                        party_name: entry.party?.name || entry.accounts?.name || 'General',
                        narration: (entry.narration || '').replace(/^Ref: N\/A - /, '').trim(),
                        // ✅ Only accumulate if THIS row is a cash/bank account row
                        debit: isCashOrBank ? (Number(entry.debit_amount) || 0) : 0,
                        credit: isCashOrBank ? (Number(entry.credit_amount) || 0) : 0,
                        reconciled: entry.reconciliation_status || false,
                        is_reversed: entry.is_reversed || false,
                        is_cash_tx: isCashOrBank,
                        mode: 'CASH/BANK', // will be reclassified in second pass
                        nominal_value: 0,
                    });
                } else {
                    const existing = groupedMap.get(vNo)!;
                    if (isCashOrBank) {
                        // ✅ Accumulate cash/bank amounts (handles multi-line cash vouchers)
                        existing.debit += (Number(entry.debit_amount) || 0);
                        existing.credit += (Number(entry.credit_amount) || 0);
                        existing.is_cash_tx = true;
                    }
                    // Prefer party name over account name for display
                    if (entry.party?.name) existing.party_name = entry.party.name;
                }
            });

            // ✅ RULE 3: Second pass — classify mode using is_cash_tx flag (NOT debit===0&&credit===0)
            const finalTransactions = Array.from(groupedMap.values()).map(t => {
                if (!t.is_cash_tx) {
                    // No cash/bank account touched → Party-to-Party Ledger Adjustment
                    // Calculate nominal for display only (never used in totals)
                    const originalEntries = entries.filter(e => e.voucher_no === t.voucher_no);
                    const nominal = originalEntries.length > 0
                        ? Math.max(...originalEntries.map(e => Math.max(Number(e.debit_amount) || 0, Number(e.credit_amount) || 0)))
                        : 0;
                    return { ...t, mode: 'LEDGER_ONLY' as TxMode, nominal_value: nominal };
                }

                if (t.debit > 0 && t.credit > 0) {
                    // ✅ RULE 4: Both sides of cash → Internal Transfer (Cash→Bank or Bank→Cash)
                    // Display both but EXCLUDE from Net Variance
                    return { ...t, mode: 'INTERNAL_TRANSFER' as TxMode };
                }

                return {
                    ...t,
                    mode: 'CASH/BANK' as TxMode,
                    fuel_name: fuelDetailMap.get(t.voucher_no)?.fuel_name,
                    quantity: fuelDetailMap.get(t.voucher_no)?.quantity,
                    rate_per_unit: fuelDetailMap.get(t.voucher_no)?.rate_per_unit,
                    total_amount: fuelDetailMap.get(t.voucher_no)?.total_amount,
                };
            });

            // Sort by time then voucher number
            const sorted = finalTransactions.sort((a, b) => {
                const timeDiff = new Date(a.raw_created_at).getTime() - new Date(b.raw_created_at).getTime();
                if (timeDiff !== 0) return timeDiff;
                return a.voucher_no.localeCompare(b.voucher_no);
            });

            // ✅ NEW: Build a map of voucher_no → all raw ledger entries (for drill-down)
            const rawEntriesByVoucher: Record<string, any[]> = {};
            entries.forEach((entry: any) => {
                const vNo = entry.voucher_no;
                if (!rawEntriesByVoucher[vNo]) rawEntriesByVoucher[vNo] = [];
                rawEntriesByVoucher[vNo].push(entry);
            });

            return { transactions: sorted, rawEntriesByVoucher };
        },
    });

    // Destructure query result safely
    const transactions = queryResult?.transactions ?? [];
    const rawEntriesByVoucher = queryResult?.rawEntriesByVoucher ?? {};

    // ✅ RULE 5: Pure ledger totals — exclude reversed, exclude INTERNAL_TRANSFER, exclude LEDGER_ONLY
    // ✅ RULE 6: Zero nominal_value in totals
    // Note: transactions is now always an array (defaulted above)
    const totals = transactions.reduce(
        (acc, t) => {
            // Skip reversed entries and their reversal counterparts
            if (t.is_reversed || t.voucher_no.startsWith('REV-')) return acc;
            // Skip non-cash (LEDGER_ONLY)
            if (t.mode === 'LEDGER_ONLY') return acc;
            // Skip internal transfers (they net to zero, should not distort variance)
            if (t.mode === 'INTERNAL_TRANSFER') return acc;

            // ✅ Pure accounting: trust the ledger values directly
            return {
                debit: acc.debit + (t.debit || 0),
                credit: acc.credit + (t.credit || 0),
            };
        },
        { debit: 0, credit: 0 }
    );

    const netVariance = totals.debit - totals.credit;

    const reconcileMutation = useMutation({
        mutationFn: async (voucherNo: string) => {
            const { error } = await (supabase as any).rpc('mark_as_reconciled', { p_voucher_no: voucherNo });
            if (error) throw error;
        },
        onSuccess: () => {
            toast({ title: 'Reconciled', description: 'Transaction marked as verified.' });
            queryClient.invalidateQueries({ queryKey: ['roznamcha-v2'] });
        },
        onError: (e: any) => toast({ variant: 'destructive', title: 'Error', description: e.message }),
    });

    const getTypeLabel = (type: string) => {
        switch (type) {
            case 'sale': return 'Sale';
            case 'purchase': return 'Purchase';
            case 'receipt': return 'Receipt';
            case 'payment': return 'Payment';
            case 'munshi_voucher': return 'Transaction';
            case 'manage_transaction': return 'Transfer';
            default: return type.replace(/_/g, ' ').replace(/\b\w/g, l => l.toUpperCase());
        }
    };

    const getModeStyle = (mode: TxMode) => {
        switch (mode) {
            case 'CASH/BANK': return 'bg-emerald-600 text-white border-emerald-700';
            case 'INTERNAL_TRANSFER': return 'bg-blue-100 text-blue-700 border-blue-300';
            case 'LEDGER_ONLY': return 'bg-amber-100 text-amber-700 border-amber-300';
        }
    };

    const getModeLabel = (mode: TxMode) => {
        switch (mode) {
            case 'CASH/BANK': return 'CASH/BANK';
            case 'INTERNAL_TRANSFER': return 'INT. TRANSFER';
            case 'LEDGER_ONLY': return 'LEDGER ONLY';
        }
    };

    return (
        <DashboardLayout>
            <div className="max-w-7xl mx-auto pb-20">

                {/* TEST PAGE BANNER */}
                <div className="bg-amber-50 border-b-2 border-amber-400 px-4 py-2 flex items-center gap-2 print:hidden">
                    <FlaskConical className="h-4 w-4 text-amber-600" />
                    <span className="text-xs font-black text-amber-700 uppercase tracking-wider">
                        TEST PAGE — Roznamcha V2 (Hardened Logic) — Route: /roznamcha-v2
                    </span>
                    <span className="ml-auto text-[10px] text-amber-500 font-bold">Original /roznamcha is untouched</span>
                </div>

                {/* FILTER BAR */}
                <div className="sticky top-0 z-10 bg-white border-b border-slate-200 shadow-sm print:hidden px-4 py-3">
                    <div className="max-w-7xl mx-auto flex flex-wrap items-center justify-between gap-4">
                        <div>
                            <h1 className="text-lg font-black text-slate-900 uppercase tracking-tighter">Naveed Musazai</h1>
                            <p className="text-xs text-slate-500 font-medium">Daily Cash & Bank Book — Roznamcha V2</p>
                        </div>

                        <div className="flex flex-wrap items-center gap-3 bg-slate-50 p-2 border border-slate-200 rounded-sm">
                            <Button
                                variant="outline" size="icon"
                                onClick={() => { const d = new Date(selectedDate); d.setDate(d.getDate() - 1); setSelectedDate(d.toISOString().split('T')[0]); }}
                                className="h-8 w-8 rounded-none border-slate-300"
                            >
                                <ChevronLeft className="h-4 w-4 text-slate-600" />
                            </Button>
                            <div className="flex flex-col">
                                <label className="text-[9px] font-bold uppercase text-slate-500 mb-1">Journal Date</label>
                                <input
                                    type="date"
                                    value={selectedDate}
                                    onChange={(e) => setSelectedDate(e.target.value)}
                                    className="h-8 px-2 border border-slate-300 rounded-none font-bold text-xs"
                                />
                            </div>
                            <Button
                                variant="outline" size="icon"
                                onClick={() => { const d = new Date(selectedDate); d.setDate(d.getDate() + 1); setSelectedDate(d.toISOString().split('T')[0]); }}
                                className="h-8 w-8 rounded-none border-slate-300"
                            >
                                <ChevronRight className="h-4 w-4 text-slate-600" />
                            </Button>
                            <div className="w-px h-6 bg-slate-200 mx-1" />
                            <Button
                                variant="secondary" size="sm"
                                onClick={() => setSelectedDate(new Date().toISOString().split('T')[0])}
                                className="h-8 px-3 text-[10px] font-bold bg-slate-200 text-slate-700 hover:bg-slate-300 rounded-none uppercase tracking-wide"
                            >
                                Today
                            </Button>
                        </div>
                    </div>
                </div>

                <div className="px-4 space-y-6 mt-4">

                    {/* SUMMARY CARDS */}
                    <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
                        <div className="summary-card">
                            <span className="summary-label text-assets font-black">Total Inward (Cash/Bank)</span>
                            <span className="summary-value text-assets">{formatPKR(totals.debit)}</span>
                            <span className="text-[9px] text-slate-400 font-medium">Excludes Internal Transfers & Ledger-Only</span>
                        </div>
                        <div className="summary-card">
                            <span className="summary-label text-liabilities font-black">Total Outward (Cash/Bank)</span>
                            <span className="summary-value text-liabilities">{formatPKR(totals.credit)}</span>
                            <span className="text-[9px] text-slate-400 font-medium">Excludes Internal Transfers & Ledger-Only</span>
                        </div>
                        <div className={cn(
                            "summary-card border-l-4",
                            netVariance >= 0 ? "border-l-emerald-500 bg-emerald-50/20 text-assets" : "border-l-rose-500 bg-rose-50/20 text-liabilities"
                        )}>
                            <span className="summary-label font-black">Daily Net Variance</span>
                            <span className="summary-value num-audit">
                                {netVariance === 0 ? '0.00' : formatPKR(Math.abs(netVariance))}
                                {netVariance !== 0 && (
                                    <span className="text-[10px] ml-1 uppercase">{netVariance >= 0 ? 'Dr' : 'Cr'}</span>
                                )}
                            </span>
                        </div>
                        {/* Legend */}
                        <div className="summary-card bg-slate-50/50 border-slate-200">
                            <span className="summary-label font-black text-slate-500">Mode Legend</span>
                            <div className="flex flex-col gap-1.5 mt-1">
                                <span className="text-[9px] flex items-center gap-1.5"><span className="px-1.5 py-0.5 bg-emerald-600 text-white font-black text-[8px] rounded-sm">CASH/BANK</span> Counted in totals</span>
                                <span className="text-[9px] flex items-center gap-1.5"><span className="px-1.5 py-0.5 bg-blue-100 text-blue-700 font-black text-[8px] rounded-sm border border-blue-300">INT. TRANSFER</span> Visible, not in net</span>
                                <span className="text-[9px] flex items-center gap-1.5"><span className="px-1.5 py-0.5 bg-amber-100 text-amber-700 font-black text-[8px] rounded-sm border border-amber-300">LEDGER ONLY</span> Party-to-Party, no cash</span>
                            </div>
                        </div>
                    </div>

                    {/* TRANSACTIONS TABLE */}
                    <div>
                        {isLoading ? (
                            <div className="flex flex-col items-center justify-center py-24 gap-4">
                                <Loader2 className="h-10 w-10 animate-spin text-slate-300" />
                                <span className="text-[10px] font-black text-slate-400 uppercase tracking-[0.2em]">Synchronizing Daily Ledger...</span>
                            </div>
                        ) : transactions.length > 0 ? (
                            <div className="border border-slate-300">
                                <table className="ledger-table">
                                    <thead>
                                        <tr className="bg-slate-900">
                                            <th className="w-20 !text-white">Time</th>
                                            <th className="w-32 !text-white">Voucher No</th>
                                            <th className="w-48 !text-white">Type & Mode</th>
                                            <th className="!text-white">Particulars / Description</th>
                                            <th className="right-align w-36 !text-white">
                                                Inward (+)<br />
                                                <span className="text-[9px] font-normal tracking-normal text-slate-300">Cash/Bank Received</span>
                                            </th>
                                            <th className="right-align w-36 !text-white">
                                                Outward (-)<br />
                                                <span className="text-[9px] font-normal tracking-normal text-slate-300">Cash/Bank Paid</span>
                                            </th>
                                            <th className="center-align w-16 !text-white print:hidden">Verif</th>
                                            <th className="center-align w-20 !text-white print:hidden">Edit</th>
                                            <th className="center-align w-14 !text-white print:hidden" title="View full journal entries">Ledger</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {transactions.map((t) => {
                                            const isReversed = t.is_reversed || t.voucher_no.startsWith('REV-');
                                            const rowColor =
                                                isReversed ? 'bg-slate-100 opacity-50' :
                                                    t.mode === 'INTERNAL_TRANSFER' ? 'bg-blue-50/40 hover:bg-blue-100/50' :
                                                        t.mode === 'LEDGER_ONLY' ? 'bg-amber-50/30 hover:bg-amber-50/50' :
                                                            t.debit > 0 ? 'bg-emerald-50/40 hover:bg-emerald-100/60' :
                                                                t.credit > 0 ? 'bg-rose-50/40 hover:bg-rose-100/60' :
                                                                    'bg-slate-50';

                                            const isExpanded = expandedVoucher === t.voucher_no;
                                            const drillEntries = rawEntriesByVoucher[t.voucher_no] || [];

                                            return (
                                                <>
                                                    <tr
                                                        key={t.id}
                                                        className={cn('transition-colors', rowColor, isExpanded && 'ring-2 ring-inset ring-indigo-400')}
                                                    >
                                                        <td className="num-audit text-xs">{t.time}</td>
                                                        <td className="num-audit text-xs !font-medium text-slate-500">
                                                            {shortVoucherId(t.voucher_no)}
                                                            {isReversed && <span className="ml-1 text-[8px] bg-slate-400 text-white px-1 rounded">VOID</span>}
                                                        </td>
                                                        <td>
                                                            <div className="flex flex-col gap-1">
                                                                <span className="font-bold uppercase text-xs">{getTypeLabel(t.type)}</span>
                                                                <span className={cn(
                                                                    'text-[10px] font-black px-1.5 py-0.5 w-fit border rounded-sm',
                                                                    getModeStyle(t.mode)
                                                                )}>
                                                                    {getModeLabel(t.mode)}
                                                                </span>
                                                            </div>
                                                        </td>
                                                        <td>
                                                            <div className="flex flex-col">
                                                                <span className="font-bold text-slate-900 uppercase text-xs tracking-tight">{t.party_name}</span>
                                                                <span className="text-[11px] italic text-slate-500 font-medium">
                                                                    {(t.narration || '').replace(/^Ref: N\/A - /, '').replace(/^Ref: N\/A/, '').trim() || 'SYSTEM ENTRY'}
                                                                </span>
                                                                {t.fuel_name && t.quantity && (
                                                                    <span className="text-[10px] text-slate-400 mt-1 font-mono block">
                                                                        [{t.fuel_name}] {t.quantity.toLocaleString()} L × {t.rate_per_unit?.toLocaleString()} = {t.total_amount?.toLocaleString()}
                                                                    </span>
                                                                )}
                                                            </div>
                                                        </td>

                                                        {/* ✅ RULE: Inward = only if cash/bank was debited */}
                                                        <td className="right-align num-audit font-bold text-sm">
                                                            {t.mode === 'LEDGER_ONLY' ? (
                                                                <span className="text-slate-300 italic font-normal text-xs">
                                                                    {t.nominal_value > 0 ? formatPKR(t.nominal_value).replace('Rs. ', '') : '-'}
                                                                </span>
                                                            ) : t.debit > 0 ? (
                                                                <span className="text-emerald-700">{formatPKR(t.debit).replace('Rs. ', '')}</span>
                                                            ) : '-'}
                                                        </td>

                                                        {/* ✅ RULE: Outward = only if cash/bank was credited */}
                                                        <td className="right-align num-audit font-bold text-sm">
                                                            {t.mode === 'LEDGER_ONLY' ? (
                                                                <span className="text-slate-300 italic font-normal text-xs">-</span>
                                                            ) : t.credit > 0 ? (
                                                                <span className="text-rose-700">{formatPKR(t.credit).replace('Rs. ', '')}</span>
                                                            ) : '-'}
                                                        </td>

                                                        <td className="center-align print:hidden">
                                                            <button
                                                                onClick={() => !t.reconciled && reconcileMutation.mutate(t.voucher_no)}
                                                                disabled={t.reconciled || reconcileMutation.isPending}
                                                                className={cn(
                                                                    'p-1.5 rounded-full transition-all',
                                                                    t.reconciled ? 'text-emerald-600' : 'text-slate-300 hover:text-emerald-400'
                                                                )}
                                                            >
                                                                {t.reconciled ? <ShieldCheck className="h-4 w-4" /> : <CheckCircle className="h-4 w-4" />}
                                                            </button>
                                                        </td>
                                                        <td className="center-align print:hidden">
                                                            <Button
                                                                variant="ghost" size="icon"
                                                                className="h-7 w-7 text-slate-400 hover:text-slate-900"
                                                                onClick={() => {
                                                                    if (t.type === 'sale' || t.type === 'purchase' || t.type === 'transfer' || t.type === 'manage_transaction') {
                                                                        navigate(`/manage-transactions?edit=${t.voucher_no}`);
                                                                    } else if (t.type === 'receipt' || t.type === 'payment') {
                                                                        navigate(`/expenses?edit=${t.voucher_no}`);
                                                                    } else {
                                                                        toast({ title: 'System Notice', description: 'Journal entries must be reversed for security.' });
                                                                    }
                                                                }}
                                                            >
                                                                <Edit2 className="h-3.5 w-3.5" />
                                                            </Button>
                                                        </td>

                                                        {/* ✅ NEW: Ledger drill-down toggle button */}
                                                        <td className="center-align print:hidden">
                                                            <button
                                                                onClick={() => toggleExpand(t.voucher_no)}
                                                                title="View full journal entries for this voucher"
                                                                className={cn(
                                                                    'p-1.5 rounded-full transition-all flex items-center gap-0.5',
                                                                    isExpanded
                                                                        ? 'text-indigo-600 bg-indigo-50'
                                                                        : 'text-slate-300 hover:text-indigo-500 hover:bg-indigo-50'
                                                                )}
                                                            >
                                                                <BookOpen className="h-4 w-4" />
                                                                <ChevronDown className={cn('h-3 w-3 transition-transform', isExpanded && 'rotate-180')} />
                                                            </button>
                                                        </td>
                                                    </tr>

                                                    {/* ✅ NEW: Expandable ledger drill-down row */}
                                                    {isExpanded && (
                                                        <tr key={`${t.id}-drill`} className="bg-indigo-50/60">
                                                            <td colSpan={9} className="px-6 py-3">
                                                                <div className="border border-indigo-200 rounded-sm overflow-hidden">
                                                                    {/* Drill-down header */}
                                                                    <div className="bg-indigo-900 text-white px-4 py-2 flex items-center gap-2">
                                                                        <BookOpen className="h-3.5 w-3.5" />
                                                                        <span className="text-[10px] font-black uppercase tracking-widest">
                                                                            Full Journal — {t.voucher_no}
                                                                        </span>
                                                                        <span className="ml-auto text-[9px] text-indigo-300 font-medium">
                                                                            {drillEntries.length} journal line{drillEntries.length !== 1 ? 's' : ''}
                                                                        </span>
                                                                    </div>
                                                                    {/* Drill-down table */}
                                                                    <table className="w-full text-xs">
                                                                        <thead>
                                                                            <tr className="bg-indigo-100 border-b border-indigo-200">
                                                                                <th className="px-4 py-1.5 text-left text-[9px] font-black uppercase text-indigo-700 tracking-wider w-24">Acc Code</th>
                                                                                <th className="px-4 py-1.5 text-left text-[9px] font-black uppercase text-indigo-700 tracking-wider">Account Name</th>
                                                                                <th className="px-4 py-1.5 text-left text-[9px] font-black uppercase text-indigo-700 tracking-wider">Party</th>
                                                                                <th className="px-4 py-1.5 text-right text-[9px] font-black uppercase text-emerald-700 tracking-wider w-36">Debit (Dr)</th>
                                                                                <th className="px-4 py-1.5 text-right text-[9px] font-black uppercase text-rose-700 tracking-wider w-36">Credit (Cr)</th>
                                                                                <th className="px-4 py-1.5 text-center text-[9px] font-black uppercase text-indigo-700 tracking-wider w-20">Cash/Bank?</th>
                                                                            </tr>
                                                                        </thead>
                                                                        <tbody className="bg-white divide-y divide-indigo-50">
                                                                            {drillEntries.map((entry: any, idx: number) => {
                                                                                const isCash = CASH_BANK_CODES.includes(entry.accounts?.code);
                                                                                return (
                                                                                    <tr key={idx} className={cn(
                                                                                        'transition-colors',
                                                                                        isCash ? 'bg-emerald-50/50' : 'bg-white'
                                                                                    )}>
                                                                                        <td className="px-4 py-2 font-mono font-black text-slate-500 text-[10px]">
                                                                                            {entry.accounts?.code || '—'}
                                                                                        </td>
                                                                                        <td className="px-4 py-2 font-bold text-slate-800 uppercase text-[10px]">
                                                                                            {entry.accounts?.name || '—'}
                                                                                        </td>
                                                                                        <td className="px-4 py-2 text-slate-500 text-[10px]">
                                                                                            {entry.party?.name || <span className="text-slate-300 italic">—</span>}
                                                                                        </td>
                                                                                        <td className="px-4 py-2 text-right font-black text-emerald-700 num-audit">
                                                                                            {Number(entry.debit_amount) > 0
                                                                                                ? formatPKR(Number(entry.debit_amount)).replace('Rs. ', '')
                                                                                                : <span className="text-slate-200">—</span>}
                                                                                        </td>
                                                                                        <td className="px-4 py-2 text-right font-black text-rose-700 num-audit">
                                                                                            {Number(entry.credit_amount) > 0
                                                                                                ? formatPKR(Number(entry.credit_amount)).replace('Rs. ', '')
                                                                                                : <span className="text-slate-200">—</span>}
                                                                                        </td>
                                                                                        <td className="px-4 py-2 text-center">
                                                                                            {isCash
                                                                                                ? <span className="px-1.5 py-0.5 bg-emerald-600 text-white text-[8px] font-black rounded-sm">✓ CASH/BANK</span>
                                                                                                : <span className="text-slate-300 text-[9px]">—</span>}
                                                                                        </td>
                                                                                    </tr>
                                                                                );
                                                                            })}
                                                                        </tbody>
                                                                        {/* Drill-down totals row */}
                                                                        <tfoot className="bg-indigo-100 border-t-2 border-indigo-300">
                                                                            <tr>
                                                                                <td colSpan={3} className="px-4 py-1.5 text-right text-[9px] font-black uppercase text-indigo-700">Voucher Totals:</td>
                                                                                <td className="px-4 py-1.5 text-right font-black text-emerald-700 num-audit text-xs">
                                                                                    {formatPKR(drillEntries.reduce((s: number, e: any) => s + (Number(e.debit_amount) || 0), 0)).replace('Rs. ', '')}
                                                                                </td>
                                                                                <td className="px-4 py-1.5 text-right font-black text-rose-700 num-audit text-xs">
                                                                                    {formatPKR(drillEntries.reduce((s: number, e: any) => s + (Number(e.credit_amount) || 0), 0)).replace('Rs. ', '')}
                                                                                </td>
                                                                                <td className="px-4 py-1.5 text-center">
                                                                                    {/* Balanced check */}
                                                                                    {(() => {
                                                                                        const totalDr = drillEntries.reduce((s: number, e: any) => s + (Number(e.debit_amount) || 0), 0);
                                                                                        const totalCr = drillEntries.reduce((s: number, e: any) => s + (Number(e.credit_amount) || 0), 0);
                                                                                        return Math.abs(totalDr - totalCr) < 0.01
                                                                                            ? <span className="text-[8px] font-black text-emerald-700 bg-emerald-100 px-1 py-0.5 rounded">✓ BALANCED</span>
                                                                                            : <span className="text-[8px] font-black text-rose-700 bg-rose-100 px-1 py-0.5 rounded">⚠ UNBALANCED</span>;
                                                                                    })()}
                                                                                </td>
                                                                            </tr>
                                                                        </tfoot>
                                                                    </table>
                                                                </div>
                                                            </td>
                                                        </tr>
                                                    )}
                                                </>
                                            );
                                        })}
                                    </tbody>
                                    <tfoot className="bg-slate-50 font-black border-t-2 border-slate-900">
                                        <tr>
                                            <td colSpan={4} className="px-4 py-3 right-align uppercase text-xs">
                                                Closing Totals (Cash & Bank only) for {selectedDate}:
                                            </td>
                                            <td className="px-4 py-3 right-align text-xl text-emerald-700 num-audit underline decoration-double">
                                                {formatPKR(totals.debit)}
                                            </td>
                                            <td className="px-4 py-3 right-align text-xl text-rose-700 num-audit underline decoration-double">
                                                {formatPKR(totals.credit)}
                                            </td>
                                            <td colSpan={3} />
                                        </tr>
                                        {/* Internal Transfers info row */}
                                        {transactions.some(t => t.mode === 'INTERNAL_TRANSFER') && (
                                            <tr className="bg-blue-50">
                                                <td colSpan={8} className="px-4 py-2 text-[10px] text-blue-600 font-bold italic">
                                                    ℹ Internal Transfer entries (Cash↔Bank) are displayed above but excluded from Net Variance — they do not change total cash position.
                                                </td>
                                            </tr>
                                        )}
                                        {/* Ledger Only info row */}
                                        {transactions.some(t => t.mode === 'LEDGER_ONLY') && (
                                            <tr className="bg-amber-50">
                                                <td colSpan={8} className="px-4 py-2 text-[10px] text-amber-600 font-bold italic">
                                                    ℹ "LEDGER ONLY" entries are Party-to-Party adjustments — no physical cash moved. Shown for transparency, excluded from totals.
                                                </td>
                                            </tr>
                                        )}
                                    </tfoot>
                                </table>
                            </div>
                        ) : (
                            <div className="center-align py-32 border border-dashed border-slate-300 opacity-50 italic">
                                No ledger entries found for the selected date.
                            </div>
                        )}
                    </div>

                </div>
            </div>
        </DashboardLayout>
    );
}
