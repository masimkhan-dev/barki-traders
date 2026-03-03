// ============================================================
// RoznamchaV3.tsx — READABLE DAILY BOOK (Final Simplified)
// Route: /roznamcha-v3
// ============================================================
// DESIGN RULES (DO NOT BREAK):
// 1. Roznamcha = chronological story, not a dashboard
// 2. 3-second scan → who paid who, how much
// 3. FROM → TO in one cell with arrow (not two columns)
// 4. flow_type badge: small, muted (deposit/payment/transfer/journal)
// 5. Remarks: clean, inline, secondary tone — no "Ref:" prefix
// 6. Amount: right-aligned, comma-formatted, no Rs prefix in cells
// 7. NO totals strip. NO net movement. NO counters.
// ============================================================

import { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Button } from '@/components/ui/button';
import { supabase } from '@/integrations/supabase/client';
import {
    Loader2,
    ChevronLeft,
    ChevronRight,
    Edit2,
    Trash2,
    FlaskConical,
    BookOpen,
    ChevronDown,
    ArrowRight,
} from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { useToast } from '@/hooks/use-toast';
import { cn } from '@/lib/utils';

// ✅ Single source of truth — update here if new cash/bank account added
const CASH_BANK_CODES = ['1000', '1010'];
const CASH_CODES = ['1000'];
const BANK_CODES = ['1010'];

type FlowType = 'deposit' | 'payment' | 'transfer' | 'journal';

interface DailyRow {
    id: string;
    raw_created_at: string;
    voucher_no: string;
    short_id: string;  // e.g. #2107
    date: string;
    from_name: string;  // Credit side
    to_name: string;  // Debit side
    flow_type: FlowType;
    amount: number;
    remarks: string;  // Cleaned — no "Ref:" no trailing dash
    type: string;
    is_reversed: boolean;
}

// ── Remarks cleaner ─────────────────────────────────────────
// Removes: "Ref:" prefix, "N/A", trailing dashes, extra spaces
function cleanRemarks(raw: string): string {
    return (raw || '')
        .replace(/^Ref:\s*/i, '')
        .replace(/^N\/A\s*[-–]?\s*/i, '')
        .replace(/\s*[-–]\s*$/, '')
        .replace(/\s+/g, ' ')
        .trim();
}

// ── Voucher short ID ─────────────────────────────────────────
function shortVoucherId(voucher_no: string): string {
    // VCH-20260302-2107 → #2107
    const parts = voucher_no.split('-');
    const last = parts[parts.length - 1];
    return `#${last}`;
}

// ── Flow type badge config ───────────────────────────────────
const FLOW_CONFIG: Record<FlowType, { label: string; cls: string }> = {
    deposit: { label: 'Deposit', cls: 'bg-emerald-100 text-emerald-700 border-emerald-200' },
    payment: { label: 'Payment', cls: 'bg-rose-100 text-rose-700 border-rose-200' },
    transfer: { label: 'Transfer', cls: 'bg-blue-100 text-blue-700 border-blue-200' },
    journal: { label: 'Journal', cls: 'bg-slate-100 text-slate-500 border-slate-200' },
};

export default function RoznamchaV3() {
    const navigate = useNavigate();
    const queryClient = useQueryClient();
    const { toast } = useToast();
    const { role } = useAuth();
    const [selectedDate, setSelectedDate] = useState(
        new Date().toISOString().split('T')[0]
    );
    const [expandedVoucher, setExpandedVoucher] = useState<string | null>(null);

    const toggleExpand = (vNo: string) =>
        setExpandedVoucher(prev => prev === vNo ? null : vNo);

    // ── Shift selected date by N days ────────────────────────
    const shiftDate = (days: number) => {
        const d = new Date(selectedDate);
        d.setDate(d.getDate() + days);
        setSelectedDate(d.toISOString().split('T')[0]);
    };

    // ─────────────────────────────────────────────────────────
    // QUERY
    // ─────────────────────────────────────────────────────────
    const { data: queryResult, isLoading } = useQuery({
        queryKey: ['roznamcha-v3', selectedDate],
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
          is_reversed,
          posting_date,
          accounts!inner(code, name),
          party:parties(name)
        `)
                .eq('posting_date', selectedDate)
                .order('created_at', { ascending: true })
                .order('voucher_no', { ascending: true });

            if (error) throw error;

            const entries = (data || []) as any[];

            // ── Group by voucher_no ────────────────────────────
            const groupedMap = new Map<string, {
                id: string; raw_created_at: string; voucher_no: string;
                type: string; is_reversed: boolean; narration: string;
                posting_date: string; rows: any[];
            }>();

            entries.forEach((entry: any) => {
                const vNo = entry.voucher_no;
                if (!groupedMap.has(vNo)) {
                    groupedMap.set(vNo, {
                        id: entry.id,
                        raw_created_at: entry.created_at,
                        voucher_no: vNo,
                        type: entry.voucher_type,
                        is_reversed: entry.is_reversed || false,
                        narration: cleanRemarks(entry.narration || ''),
                        posting_date: entry.posting_date,
                        rows: [],
                    });
                }
                groupedMap.get(vNo)!.rows.push(entry);
            });

            // ── Map each voucher group → DailyRow ─────────────
            const dailyRows: DailyRow[] = [];

            groupedMap.forEach((group) => {
                const { rows, voucher_no } = group;

                // Credit side = FROM (money source)
                const creditEntry = rows.find((e: any) => Number(e.credit_amount) > 0);
                // Debit side  = TO   (money destination)
                const debitEntry = rows.find((e: any) => Number(e.debit_amount) > 0);

                const fromName = (
                    creditEntry?.party?.name || creditEntry?.accounts?.name || '—'
                ).toUpperCase();

                const toName = (
                    debitEntry?.party?.name || debitEntry?.accounts?.name || '—'
                ).toUpperCase();

                // ✅ flow_type: derived from which side of the transaction is cash/bank
                const isCreditCash = creditEntry && CASH_BANK_CODES.includes(creditEntry.accounts?.code);
                const isDebitCash = debitEntry && CASH_BANK_CODES.includes(debitEntry.accounts?.code);

                let flow_type: FlowType;
                if (isCreditCash && isDebitCash) {
                    flow_type = 'transfer';   // Cash ↔ Bank: internal
                } else if (!isCreditCash && isDebitCash) {
                    flow_type = 'deposit';    // Party → Bank/Cash: money came in
                } else if (isCreditCash && !isDebitCash) {
                    flow_type = 'payment';    // Bank/Cash → Party: money went out
                } else {
                    flow_type = 'journal';    // No cash/bank: ledger-only adjustment
                }

                // Amount = largest single value in the voucher
                const amount = Math.max(
                    ...rows.map((e: any) =>
                        Math.max(Number(e.debit_amount) || 0, Number(e.credit_amount) || 0)
                    )
                );

                dailyRows.push({
                    id: group.id,
                    raw_created_at: group.raw_created_at,
                    voucher_no,
                    short_id: shortVoucherId(voucher_no),
                    date: group.posting_date,
                    from_name: fromName,
                    to_name: toName,
                    flow_type,
                    amount,
                    remarks: group.narration,
                    type: group.type,
                    is_reversed: group.is_reversed,
                });
            });

            const sorted = dailyRows.sort((a, b) =>
                new Date(a.raw_created_at).getTime() - new Date(b.raw_created_at).getTime()
            );

            // Raw entries map for drill-down
            const rawEntriesByVoucher: Record<string, any[]> = {};
            entries.forEach((e: any) => {
                if (!rawEntriesByVoucher[e.voucher_no]) rawEntriesByVoucher[e.voucher_no] = [];
                rawEntriesByVoucher[e.voucher_no].push(e);
            });

            return { rows: sorted, rawEntriesByVoucher };
        },
    });

    const rows = queryResult?.rows ?? [];
    const rawEntriesByVoucher = queryResult?.rawEntriesByVoucher ?? {};

    // ─────────────────────────────────────────────────────────
    // DELETE
    // ─────────────────────────────────────────────────────────
    const deleteMutation = useMutation({
        mutationFn: async (voucherNo: string) => {
            const { error } = await supabase
                .from('ledger_entries')
                .delete()
                .eq('voucher_no', voucherNo);
            if (error) throw error;
        },
        onSuccess: () => {
            toast({ title: 'Entry Deleted' });
            queryClient.invalidateQueries({ queryKey: ['roznamcha-v3'] });
            queryClient.invalidateQueries({ queryKey: ['roznamcha'] });
        },
        onError: (e: any) =>
            toast({ variant: 'destructive', title: 'Error', description: e.message }),
    });

    const formatDate = (d: string) => {
        const [y, m, day] = d.split('-');
        return `${day}-${m}-${y}`;
    };

    // Day name for date header (e.g. "Monday")
    const getDayName = (iso: string) =>
        new Date(iso).toLocaleDateString('en-PK', { weekday: 'long' });

    // ─────────────────────────────────────────────────────────
    // RENDER
    // ─────────────────────────────────────────────────────────
    return (
        <DashboardLayout>
            <div className="max-w-5xl mx-auto pb-20">



                {/* ── DATE HEADER ──────────────────────────────── */}
                <div className="px-5 pt-5 pb-3 flex flex-wrap items-center justify-between gap-3 border-b border-slate-100">
                    <div className="flex items-center gap-2">
                        <span className="text-[10px] font-bold text-slate-400 uppercase tracking-wider">{getDayName(selectedDate)}</span>
                        <span className="text-sm font-black text-slate-800">{formatDate(selectedDate)}</span>
                        <ArrowRight className="h-3.5 w-3.5 text-slate-300" />
                    </div>

                    <div className="flex items-center gap-1.5">
                        <button
                            onClick={() => shiftDate(-1)}
                            className="h-7 w-7 flex items-center justify-center border border-slate-200 hover:border-slate-400 rounded text-slate-500 hover:text-slate-900 transition-colors"
                        >
                            <ChevronLeft className="h-4 w-4" />
                        </button>
                        <input
                            type="date"
                            value={selectedDate}
                            onChange={(e) => setSelectedDate(e.target.value)}
                            className="h-7 px-2 border border-slate-200 rounded text-xs font-bold text-slate-700 focus:outline-none focus:border-slate-400"
                        />
                        <button
                            onClick={() => shiftDate(1)}
                            className="h-7 w-7 flex items-center justify-center border border-slate-200 hover:border-slate-400 rounded text-slate-500 hover:text-slate-900 transition-colors"
                        >
                            <ChevronRight className="h-4 w-4" />
                        </button>
                        <button
                            onClick={() => setSelectedDate(new Date().toISOString().split('T')[0])}
                            className="h-7 px-3 border border-slate-200 hover:border-slate-400 rounded text-[10px] font-bold uppercase text-slate-600 hover:text-slate-900 transition-colors"
                        >
                            Today
                        </button>
                    </div>
                </div>

                {/* ── TABLE ────────────────────────────────────── */}
                <div className="px-4 pt-4">
                    {isLoading ? (
                        <div className="flex flex-col items-center justify-center py-32 gap-3">
                            <Loader2 className="h-7 w-7 animate-spin text-slate-200" />
                            <span className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">
                                Loading...
                            </span>
                        </div>
                    ) : rows.length > 0 ? (
                        <div className="border border-slate-200 rounded-sm overflow-hidden">
                            <table className="w-full text-sm border-collapse">
                                <thead>
                                    <tr className="border-b-2 border-slate-200 bg-white">
                                        {/* Columns: Voucher | From → To (+ remarks) | Flow | Amount | Action */}
                                        <th className="px-3 py-2 text-left text-[9px] font-black uppercase text-slate-400 tracking-wider w-24">
                                            Voucher
                                        </th>
                                        <th className="px-3 py-2 text-left text-[9px] font-black uppercase text-slate-400 tracking-wider">
                                            From → To
                                        </th>
                                        <th className="px-3 py-2 text-left text-[9px] font-black uppercase text-slate-400 tracking-wider w-24">
                                            Flow
                                        </th>
                                        <th className="px-3 py-2 text-right text-[9px] font-black uppercase text-slate-400 tracking-wider w-32">
                                            Amount
                                        </th>
                                        <th className="px-3 py-2 w-20 print:hidden" />
                                    </tr>
                                </thead>
                                <tbody className="divide-y divide-slate-100">
                                    {rows.map((row) => {
                                        const isVoid = row.is_reversed || row.voucher_no.startsWith('REV-');
                                        const isExpanded = expandedVoucher === row.voucher_no;
                                        const drillEntries = rawEntriesByVoucher[row.voucher_no] || [];
                                        const flowCfg = FLOW_CONFIG[row.flow_type];

                                        return (
                                            <>
                                                {/* ── Main row ──────────────────────────────── */}
                                                <tr
                                                    key={row.id}
                                                    className={cn(
                                                        'transition-colors border-l-2',
                                                        // ── Left accent border by flow type (visible on hover only via opacity trick)
                                                        row.flow_type === 'deposit' && 'border-l-emerald-300 hover:border-l-emerald-500 hover:bg-emerald-50/30',
                                                        row.flow_type === 'payment' && 'border-l-rose-300 hover:border-l-rose-500 hover:bg-rose-50/30',
                                                        row.flow_type === 'transfer' && 'border-l-blue-300 hover:border-l-blue-500 hover:bg-blue-50/20',
                                                        row.flow_type === 'journal' && 'border-l-slate-200 hover:border-l-slate-400 hover:bg-slate-50/60',
                                                        isVoid && 'opacity-40',
                                                        isExpanded && 'bg-indigo-50/30 border-l-indigo-400'
                                                    )}
                                                >
                                                    {/* Voucher ID */}
                                                    <td className="px-3 py-3 align-top">
                                                        <div className="flex items-center gap-1">
                                                            <button
                                                                onClick={() => toggleExpand(row.voucher_no)}
                                                                title="View journal"
                                                                className={cn(
                                                                    'p-1 rounded transition-colors shrink-0',
                                                                    isExpanded
                                                                        ? 'text-indigo-500'
                                                                        : 'text-slate-200 hover:text-indigo-400'
                                                                )}
                                                            >
                                                                <BookOpen className="h-3.5 w-3.5" />
                                                            </button>
                                                            <span className="font-mono text-[10px] font-black text-slate-500 bg-slate-100 px-1.5 py-0.5 rounded">
                                                                {row.short_id}
                                                            </span>
                                                            {isVoid && (
                                                                <span className="text-[8px] bg-slate-400 text-white px-1 rounded">
                                                                    VOID
                                                                </span>
                                                            )}
                                                        </div>
                                                    </td>

                                                    {/* FROM → TO + remarks */}
                                                    <td className="px-3 py-3 align-top">
                                                        {/* Direction line */}
                                                        <div className="flex items-center gap-1.5 flex-wrap">
                                                            <span className="font-black text-[13px] text-slate-900 uppercase tracking-tight">
                                                                {row.from_name}
                                                            </span>
                                                            <ArrowRight className="h-3 w-3 text-slate-300 shrink-0" />
                                                            <span className="font-black text-[13px] text-slate-900 uppercase tracking-tight">
                                                                {row.to_name}
                                                            </span>
                                                        </div>
                                                        {/* Remarks — secondary, clean */}
                                                        {row.remarks && (
                                                            <p className="text-[10px] text-slate-300 mt-0.5 leading-snug italic">
                                                                {row.remarks}
                                                            </p>
                                                        )}
                                                    </td>

                                                    {/* Flow badge — small, muted */}
                                                    <td className="px-3 py-3 align-top">
                                                        <span className={cn(
                                                            'inline-block px-2 py-0.5 text-[10px] font-bold rounded border',
                                                            flowCfg.cls
                                                        )}>
                                                            {flowCfg.label}
                                                        </span>
                                                    </td>

                                                    {/* Amount — right-aligned, comma, no Rs */}
                                                    <td className={cn(
                                                        'px-3 py-3 align-top text-right font-black tabular-nums text-base tracking-tight',
                                                        row.flow_type === 'deposit' ? 'text-emerald-700' :
                                                            row.flow_type === 'payment' ? 'text-rose-700' :
                                                                row.flow_type === 'transfer' ? 'text-blue-700' :
                                                                    'text-slate-400',
                                                        isVoid && 'line-through'
                                                    )}>
                                                        {row.amount > 0 ? row.amount.toLocaleString('en-PK') : '—'}
                                                    </td>

                                                    {/* Actions */}
                                                    <td className="px-3 py-3 align-top print:hidden">
                                                        <div className="flex items-center justify-end gap-0.5">
                                                            <Button
                                                                variant="ghost" size="icon"
                                                                className="h-6 w-6 text-slate-300 hover:text-slate-700"
                                                                title="Edit"
                                                                onClick={() => {
                                                                    if (['sale', 'purchase', 'transfer', 'manage_transaction', 'munshi_voucher'].includes(row.type)) {
                                                                        navigate(`/manage-transactions?edit=${row.voucher_no}`);
                                                                    } else if (['receipt', 'payment'].includes(row.type)) {
                                                                        navigate(`/expenses?edit=${row.voucher_no}`);
                                                                    } else {
                                                                        toast({ title: 'Reverse this entry to edit.' });
                                                                    }
                                                                }}
                                                            >
                                                                <Edit2 className="h-3 w-3" />
                                                            </Button>
                                                            {(role === 'admin') && (
                                                                <Button
                                                                    variant="ghost" size="icon"
                                                                    className="h-6 w-6 text-slate-200 hover:text-rose-500"
                                                                    title="Delete"
                                                                    disabled={deleteMutation.isPending}
                                                                    onClick={() => {
                                                                        if (confirm(`Delete ${row.voucher_no}?`)) {
                                                                            deleteMutation.mutate(row.voucher_no);
                                                                        }
                                                                    }}
                                                                >
                                                                    <Trash2 className="h-3 w-3" />
                                                                </Button>
                                                            )}
                                                        </div>
                                                    </td>
                                                </tr>

                                                {/* ── Expandable journal drill-down ─────────── */}
                                                {isExpanded && (
                                                    <tr key={`${row.id}-drill`}>
                                                        <td colSpan={5} className="px-5 py-3 bg-indigo-50/40">
                                                            <div className="border border-indigo-200 rounded overflow-hidden">
                                                                {/* Header */}
                                                                <div className="bg-indigo-900 text-white px-4 py-1.5 flex items-center gap-2">
                                                                    <BookOpen className="h-3 w-3" />
                                                                    <span className="text-[9px] font-black uppercase tracking-widest">
                                                                        Full Journal — {row.voucher_no}
                                                                    </span>
                                                                    <span className="ml-auto text-[9px] text-indigo-300">
                                                                        {drillEntries.length} lines
                                                                    </span>
                                                                </div>

                                                                {/* Journal table */}
                                                                <table className="w-full text-xs">
                                                                    <thead>
                                                                        <tr className="bg-indigo-100 border-b border-indigo-200">
                                                                            <th className="px-3 py-1.5 text-left text-[9px] font-black uppercase text-indigo-600 w-16">Code</th>
                                                                            <th className="px-3 py-1.5 text-left text-[9px] font-black uppercase text-indigo-600">Account</th>
                                                                            <th className="px-3 py-1.5 text-left text-[9px] font-black uppercase text-indigo-600">Party</th>
                                                                            <th className="px-3 py-1.5 text-right text-[9px] font-black uppercase text-emerald-600 w-28">Dr</th>
                                                                            <th className="px-3 py-1.5 text-right text-[9px] font-black uppercase text-rose-600 w-28">Cr</th>
                                                                            <th className="px-3 py-1.5 text-center text-[9px] font-black uppercase text-indigo-600 w-20">Type</th>
                                                                        </tr>
                                                                    </thead>
                                                                    <tbody className="bg-white divide-y divide-slate-50">
                                                                        {drillEntries.map((entry: any, idx: number) => {
                                                                            const isCash = CASH_BANK_CODES.includes(entry.accounts?.code);
                                                                            return (
                                                                                <tr key={idx} className={isCash ? 'bg-emerald-50/30' : 'bg-white'}>
                                                                                    <td className="px-3 py-2 font-mono text-[10px] text-slate-400">
                                                                                        {entry.accounts?.code || '—'}
                                                                                    </td>
                                                                                    <td className="px-3 py-2 font-bold text-slate-700 uppercase text-[10px]">
                                                                                        {entry.accounts?.name || '—'}
                                                                                    </td>
                                                                                    <td className="px-3 py-2 text-slate-400 text-[10px]">
                                                                                        {entry.party?.name || <span className="text-slate-200">—</span>}
                                                                                    </td>
                                                                                    <td className="px-3 py-1.5 text-right font-bold text-emerald-700 tabular-nums">
                                                                                        {Number(entry.debit_amount) > 0
                                                                                            ? Number(entry.debit_amount).toLocaleString('en-PK')
                                                                                            : <span className="text-slate-200">—</span>}
                                                                                    </td>
                                                                                    <td className="px-3 py-1.5 text-right font-bold text-rose-700 tabular-nums">
                                                                                        {Number(entry.credit_amount) > 0
                                                                                            ? Number(entry.credit_amount).toLocaleString('en-PK')
                                                                                            : <span className="text-slate-200">—</span>}
                                                                                    </td>
                                                                                    <td className="px-3 py-2 text-center">
                                                                                        {isCash
                                                                                            ? <span className="px-1.5 py-0.5 bg-emerald-600 text-white text-[8px] font-black rounded-sm">CASH/BANK</span>
                                                                                            : <span className="text-slate-300 text-[9px]">ledger</span>}
                                                                                    </td>
                                                                                </tr>
                                                                            );
                                                                        })}
                                                                    </tbody>
                                                                    <tfoot className="bg-indigo-100 border-t border-indigo-200">
                                                                        <tr>
                                                                            <td colSpan={3} className="px-3 py-1.5 text-right text-[9px] font-black uppercase text-indigo-600">
                                                                                Total:
                                                                            </td>
                                                                            <td className="px-3 py-1.5 text-right font-black text-emerald-700 tabular-nums text-[10px]">
                                                                                {drillEntries.reduce((s: number, e: any) => s + (Number(e.debit_amount) || 0), 0).toLocaleString('en-PK')}
                                                                            </td>
                                                                            <td className="px-3 py-1.5 text-right font-black text-rose-700 tabular-nums text-[10px]">
                                                                                {drillEntries.reduce((s: number, e: any) => s + (Number(e.credit_amount) || 0), 0).toLocaleString('en-PK')}
                                                                            </td>
                                                                            <td className="px-3 py-1.5 text-center">
                                                                                {(() => {
                                                                                    const dr = drillEntries.reduce((s: number, e: any) => s + (Number(e.debit_amount) || 0), 0);
                                                                                    const cr = drillEntries.reduce((s: number, e: any) => s + (Number(e.credit_amount) || 0), 0);
                                                                                    return Math.abs(dr - cr) < 0.01
                                                                                        ? <span className="text-[8px] font-black text-emerald-700">✓ balanced</span>
                                                                                        : <span className="text-[8px] font-black text-rose-700">⚠ unbalanced</span>;
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
                            </table>
                        </div>
                    ) : (
                        <div className="py-32 text-center text-slate-300 text-sm italic border border-dashed border-slate-100 rounded">
                            No entries for {formatDate(selectedDate)}.
                        </div>
                    )}
                </div>

                {/* Row count — minimal, no totals */}
                {!isLoading && rows.length > 0 && (
                    <p className="px-5 mt-2 text-[10px] text-slate-300 font-medium">
                        {rows.length} voucher{rows.length !== 1 ? 's' : ''} · {formatDate(selectedDate)}
                    </p>
                )}

            </div>
        </DashboardLayout>
    );
}
