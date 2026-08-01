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

import { useState, Fragment } from 'react';
import { useQuery } from '@tanstack/react-query';
import { useNavigate } from 'react-router-dom';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Button } from '@/components/ui/button';
import { supabase } from '@/integrations/supabase/client';
import {
    Loader2,
    ChevronLeft,
    ChevronRight,
    Edit2,
    RotateCcw,
    FlaskConical,
    BookOpen,
    ChevronDown,
    ArrowRight,
    ShoppingCart,
    Fuel,
    Landmark,
    Notebook,
    Package,
    Undo,
    Coins,
    CreditCard,
} from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { useToast } from '@/hooks/use-toast';
import { PHASE2_COMING_MESSAGE } from '@/lib/phase1-readonly';
import { ReversalModal } from '@/components/modals/ReversalModal';
import { cn } from '@/lib/utils';

// ✅ Single source of truth — update here if new cash/bank account added
const CASH_BANK_CODES = ['1000', '1010'];
const CASH_CODES = ['1000'];
const BANK_CODES = ['1010'];

type FlowType = 'deposit' | 'payment' | 'transfer' | 'sale' | 'purchase' | 'journal';

interface DailyRow {
    id: string;
    raw_created_at: string;
    voucher_no: string;
    short_id: string;  // e.g. #2107
    date: string;
    from_name: string;  // Credit side
    to_name: string;  // Debit side
    from_code?: string;
    to_code?: string;
    flow_type: FlowType;
    amount: number;
    remarks: string;  // Cleaned — no "Ref:" no trailing dash
    type: string;
    is_reversed: boolean;
    fuel_name?: string;
    quantity?: number;
    rate_per_unit?: number;
    total_amount?: number;
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
    if (!voucher_no) return '#—';
    const parts = voucher_no.split('-');
    const prefix = parts[0] || 'VCH';
    const last = parts[parts.length - 1];
    const seq = last.length > 7 ? last.slice(-5) : last;
    return `${prefix}·${seq}`;
}

// ── ERP Transaction Badge Config ─────────────────────────────
// ── Account Classification Helpers ──────────────────────────
function isCashAccount(code: string, name: string): boolean {
    const c = (code || '').trim();
    const n = (name || '').toLowerCase();
    return c === '1000' || n.includes('cash on hand') || n === 'cash' || n.includes('cash');
}

function isBankAccount(code: string, name: string): boolean {
    const c = (code || '').trim();
    const n = (name || '').toLowerCase();
    return c === '1010' || n.includes('bank');
}

// ── ERP Transaction Badge Config ─────────────────────────────
function getTransactionBadgeConfig(
    voucher_no: string,
    flow_type: FlowType,
    fromCode: string,
    fromName: string,
    toCode: string,
    toName: string
) {
    const upperVch = (voucher_no || '').toUpperCase();
    if (upperVch.startsWith('REV-')) {
        return {
            label: 'Reversal',
            cls: 'bg-red-50 text-red-700 border-red-200',
            Icon: Undo
        };
    }
    if (upperVch.startsWith('ADJ-')) {
        return {
            label: 'Adjustment',
            cls: 'bg-slate-100 text-slate-700 border-slate-200',
            Icon: Package
        };
    }
    if (upperVch.startsWith('SAL-') || flow_type === 'sale') {
        return {
            label: 'Fuel Sale',
            cls: 'bg-emerald-50 text-emerald-700 border-emerald-200',
            Icon: Fuel
        };
    }
    if (upperVch.startsWith('PUR-') || flow_type === 'purchase') {
        return {
            label: 'Fuel Purchase',
            cls: 'bg-blue-50 text-blue-700 border-blue-200',
            Icon: ShoppingCart
        };
    }

    const fromIsCash = isCashAccount(fromCode, fromName);
    const fromIsBank = isBankAccount(fromCode, fromName);
    const toIsCash = isCashAccount(toCode, toName);
    const toIsBank = isBankAccount(toCode, toName);

    // Case 1: Bank Transfer (Bank -> Bank)
    if (fromIsBank && toIsBank) {
        return {
            label: 'Bank Transfer',
            cls: 'bg-purple-50 text-purple-700 border-purple-200',
            Icon: Landmark
        };
    }

    // Case 4: Cash Deposit (Cash -> Bank)
    if (fromIsCash && toIsBank) {
        return {
            label: 'Cash Deposit',
            cls: 'bg-green-50 text-green-700 border-green-200',
            Icon: Coins
        };
    }

    // Case 5: Cash Withdrawal (Bank -> Cash)
    if (fromIsBank && toIsCash) {
        return {
            label: 'Cash Withdrawal',
            cls: 'bg-green-50 text-green-700 border-green-200',
            Icon: Coins
        };
    }

    // Case 2: Cash Receipt (Party/Other -> Cash)
    if (toIsCash && !fromIsCash && !fromIsBank) {
        return {
            label: 'Cash Receipt',
            cls: 'bg-green-50 text-green-700 border-green-200',
            Icon: Coins
        };
    }

    // Case 3: Cash Payment (Cash -> Party/Other)
    if (fromIsCash && !toIsCash && !toIsBank) {
        return {
            label: 'Cash Payment',
            cls: 'bg-slate-800 text-slate-100 border-slate-900',
            Icon: CreditCard
        };
    }

    // Party -> Bank (Bank Transfer)
    if (toIsBank && !fromIsCash && !fromIsBank) {
        return {
            label: 'Bank Transfer',
            cls: 'bg-purple-50 text-purple-700 border-purple-200',
            Icon: Landmark
        };
    }

    // Bank -> Party (Bank Transfer)
    if (fromIsBank && !toIsCash && !toIsBank) {
        return {
            label: 'Bank Transfer',
            cls: 'bg-purple-50 text-purple-700 border-purple-200',
            Icon: Landmark
        };
    }

    // Case 6: Journal Transfer (Neither is cash/bank)
    if (!fromIsCash && !fromIsBank && !toIsCash && !toIsBank) {
        return {
            label: 'Journal Transfer',
            cls: 'bg-orange-50 text-orange-700 border-orange-200',
            Icon: Notebook
        };
    }

    // Fallbacks
    if (flow_type === 'deposit') {
        return {
            label: 'Cash Receipt',
            cls: 'bg-green-50 text-green-700 border-green-200',
            Icon: Coins
        };
    }
    if (flow_type === 'payment') {
        return {
            label: 'Cash Payment',
            cls: 'bg-slate-800 text-slate-100 border-slate-900',
            Icon: CreditCard
        };
    }
    if (flow_type === 'transfer') {
        return {
            label: 'Bank Transfer',
            cls: 'bg-purple-50 text-purple-700 border-purple-200',
            Icon: Landmark
        };
    }

    return {
        label: 'Journal Transfer',
        cls: 'bg-orange-50 text-orange-700 border-orange-200',
        Icon: Notebook
    };
}

// ── ERP Narration / Remarks Formatting Helper ────────────────
function formatNarration(remarks: string, row: DailyRow): React.ReactNode {
    const clean = (remarks || '').trim();
    
    if (clean === 'Money movement' || clean.toLowerCase() === 'money movement') {
        if (row.flow_type === 'transfer') return 'Bank Transfer';
        if (row.flow_type === 'deposit') {
            return `Customer Receipt: ${row.from_name}`;
        }
        if (row.flow_type === 'payment') {
            return `Supplier Payment: ${row.to_name}`;
        }
        return 'Fund Transfer';
    }
    
    // Handle Purchase: "Purchase from Shokat Kakar" -> "Fuel Purchase / Supplier: Shokat Kakar"
    if (clean.toLowerCase().includes('purchase from')) {
        const parts = clean.split(/from/i);
        const supplier = parts[1] ? parts[1].trim() : row.from_name;
        return (
            <div className="space-y-0.5">
                <div className="font-semibold text-slate-800">Fuel Purchase</div>
                <div className="text-[10px] text-slate-500">Supplier: {supplier}</div>
            </div>
        );
    }
    
    // Handle Sale: "Inventory credit on sale" -> "Fuel Sale / Customer: Hilal Khan Seplair"
    if (clean.toLowerCase().includes('inventory credit on sale') || clean === 'Fuel Sales Revenue') {
        const customer = row.from_name && row.from_name !== 'INVENTORY' && !row.from_name.includes('CONTROL') ? row.from_name : row.to_name;
        return (
            <div className="space-y-0.5">
                <div className="font-semibold text-slate-800">Fuel Sale</div>
                <div className="text-[10px] text-slate-500">Customer: {customer}</div>
            </div>
        );
    }
    
    // Handle Reversals: "REVERSAL OF ..." -> "Sales Reversal / Reason: Rate Correction"
    if (clean.toUpperCase().startsWith('REVERSAL OF')) {
        return (
            <div className="space-y-0.5">
                <div className="font-semibold text-rose-700">Sales Reversal</div>
                <div className="text-[10px] text-slate-500">Ref: {clean}</div>
                <div className="text-[9px] text-slate-400 italic">Reason: Rate/Quantity Correction</div>
            </div>
        );
    }
    
    // Handle Inventory valuation residual:
    if (clean.toLowerCase().includes('final zero-stock') || clean.toLowerCase().includes('valuation residual')) {
        return (
            <div className="space-y-0.5">
                <div className="font-semibold text-slate-800">Inventory Valuation Adjustment</div>
                <div className="text-[10px] text-slate-400">System Generated</div>
            </div>
        );
    }
    
    return clean;
}


export default function RoznamchaV3() {
    const navigate = useNavigate();
    const { toast } = useToast();
    const { role } = useAuth();
    const [selectedDate, setSelectedDate] = useState(
        new Date().toISOString().split('T')[0]
    );
    const [reversalVoucherNo, setReversalVoucherNo] = useState<string | null>(null);
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
            const voucherNos = Array.from(new Set(entries.map(entry => entry.voucher_no).filter(Boolean)));

            const [salesRes, purchasesRes] = voucherNos.length > 0
                ? await Promise.all([
                    supabase
                        .from('sales')
                        .select(`voucher_no, quantity, rate_per_unit, total_amount, fuel_types(name)`)
                        .in('voucher_no', voucherNos),
                    supabase
                        .from('purchases')
                        .select(`voucher_no, quantity, rate_per_unit, total_amount, fuel_types(name)`)
                        .in('voucher_no', voucherNos)
                ])
                : [{ data: [], error: null }, { data: [], error: null }];

            if (salesRes.error) throw salesRes.error;
            if (purchasesRes.error) throw purchasesRes.error;

            const fuelDetailMap = new Map<string, any>();
            (salesRes.data || []).forEach((s: any) => {
                fuelDetailMap.set(s.voucher_no, {
                    source_type: 'sale',
                    fuel_name: s.fuel_types?.name,
                    quantity: s.quantity,
                    rate_per_unit: s.rate_per_unit,
                    total_amount: s.total_amount
                });
            });
            (purchasesRes.data || []).forEach((p: any) => {
                fuelDetailMap.set(p.voucher_no, {
                    source_type: 'purchase',
                    fuel_name: p.fuel_types?.name,
                    quantity: p.quantity,
                    rate_per_unit: p.rate_per_unit,
                    total_amount: p.total_amount
                });
            });

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
                const sourceDetail = fuelDetailMap.get(voucher_no);

                const creditEntries = rows.filter((e: any) => Number(e.credit_amount) > 0);
                const debitEntries = rows.filter((e: any) => Number(e.debit_amount) > 0);
                // Credit side = FROM (money source)
                const creditEntry = creditEntries[0];
                // Debit side  = TO   (money destination)
                const debitEntry = debitEntries[0];
                const isInventoryEntry = (entry: any) => {
                    const name = String(entry.accounts?.name || '').toLowerCase();
                    return entry.accounts?.code === '1200' || name.includes('inventory');
                };
                const isLegacyPurchase = !sourceDetail
                    && debitEntries.some(isInventoryEntry)
                    && creditEntries.some((entry: any) => entry.party?.name);

                const fromCode = creditEntry?.accounts?.code || '';
                const toCode = debitEntry?.accounts?.code || '';

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
                if (sourceDetail?.source_type === 'sale') {
                    flow_type = 'sale';
                } else if (sourceDetail?.source_type === 'purchase') {
                    flow_type = 'purchase';
                } else if (isLegacyPurchase) {
                    flow_type = 'purchase';
                } else if (isCreditCash && isDebitCash) {
                    flow_type = 'transfer';   // Cash ↔ Bank: internal
                } else if (!isCreditCash && isDebitCash) {
                    flow_type = 'deposit';    // Party → Bank/Cash: money came in
                } else if (isCreditCash && !isDebitCash) {
                    flow_type = 'payment';    // Bank/Cash → Party: money went out
                } else {
                    flow_type = 'journal';    // No cash/bank: ledger-only adjustment
                }

                // Amount = prioritize the entry with a party (Sale/Purchase rate) over internal entries like COGS
                const partyEntry = rows.find((e: any) => e.party?.name);
                const amount = sourceDetail?.total_amount ?? (
                    partyEntry
                        ? Math.max(Number(partyEntry.debit_amount) || 0, Number(partyEntry.credit_amount) || 0)
                        : Math.max(
                        ...rows.map((e: any) =>
                            Math.max(Number(e.debit_amount) || 0, Number(e.credit_amount) || 0)
                        )
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
                    from_code: fromCode,
                    to_code: toCode,
                    flow_type,
                    amount,
                    remarks: group.narration,
                    type: sourceDetail?.source_type ?? (isLegacyPurchase ? 'purchase' : group.type),
                    is_reversed: group.is_reversed,
                    fuel_name: sourceDetail?.fuel_name,
                    quantity: sourceDetail?.quantity,
                    rate_per_unit: sourceDetail?.rate_per_unit,
                    total_amount: sourceDetail?.total_amount,
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

    const formatPrettyDate = (d: string) => {
        const [y, m, day] = d.split('-');
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        const monthName = months[parseInt(m, 10) - 1] || 'Jan';
        return `${day} ${monthName} ${y}`;
    };

    // Day name for date header (e.g. "Monday")
    const getDayName = (iso: string) => {
        const [y, m, day] = iso.split('-');
        const dateObj = new Date(parseInt(y, 10), parseInt(m, 10) - 1, parseInt(day, 10));
        return dateObj.toLocaleDateString('en-US', { weekday: 'long' });
    };

    const formatDateForSummary = (d: string) => {
        const [y, m, day] = d.split('-');
        return `${day}-${m}-${y}`;
    };

    const formatDate = (d: string) => {
        const [y, m, day] = d.split('-');
        return `${day}-${m}-${y}`;
    };

    // ─────────────────────────────────────────────────────────
    // RENDER
    // ─────────────────────────────────────────────────────────
    return (
        <DashboardLayout>
            <div className="max-w-7xl mx-auto pb-20 px-4 md:px-6">



                {/* ── DATE HEADER ──────────────────────────────── */}
                <div className="px-5 pt-6 pb-4 flex flex-wrap items-center justify-between gap-4 border-b border-slate-100 bg-white">
                    <div className="flex flex-col">
                        <span className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">{getDayName(selectedDate)}</span>
                        <span className="text-xl font-extrabold text-slate-900 tracking-tight mt-0.5">{formatPrettyDate(selectedDate)}</span>
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
                        <div className="border border-slate-200 rounded-sm overflow-x-auto bg-white shadow-sm">
                            <table className="w-full text-xs border-collapse min-w-[1100px]">
                                <thead>
                                    <tr className="border-b border-slate-200 bg-slate-50/50 text-[10px] font-semibold uppercase text-slate-500 tracking-wider">
                                        <th className="px-3 py-2.5 text-left w-[110px]">Voucher</th>
                                        <th className="px-3 py-2.5 text-left w-[80px]">Time</th>
                                        <th className="px-3 py-2.5 text-left w-[140px]">Transaction Type</th>
                                        <th className="px-3 py-2.5 text-left min-w-[150px]">From</th>
                                        <th className="px-3 py-2.5 text-left min-w-[150px]">To</th>
                                        <th className="px-3 py-2.5 text-left w-[100px]">Fuel</th>
                                        <th className="px-3 py-2.5 text-right w-[100px]">Quantity</th>
                                        <th className="px-3 py-2.5 text-right w-[90px]">Rate</th>
                                        <th className="px-3 py-2.5 text-right w-[120px]">Amount</th>
                                        <th className="px-3 py-2.5 text-center w-[100px]">Status</th>
                                        <th className="px-3 py-2.5 text-right w-[100px] print:hidden">Actions</th>
                                    </tr>
                                </thead>
                                <tbody className="divide-y divide-slate-100">
                                    {rows.map((row) => {
                                        const isVoid = row.is_reversed || row.voucher_no.startsWith('REV-');
                                        const isExpanded = expandedVoucher === row.voucher_no;
                                        const drillEntries = rawEntriesByVoucher[row.voucher_no] || [];

                                        return (
                                            <Fragment key={row.voucher_no}>
                                                {/* ── Main row ──────────────────────────────── */}
                                                <tr
                                                    className={cn(
                                                        'transition-colors border-l-2 h-12',
                                                        // ── Left accent border by flow type
                                                        row.flow_type === 'deposit' && 'border-l-emerald-300 hover:border-l-emerald-500 hover:bg-emerald-50/10',
                                                        row.flow_type === 'payment' && 'border-l-rose-300 hover:border-l-rose-500 hover:bg-rose-50/10',
                                                        row.flow_type === 'transfer' && 'border-l-purple-300 hover:border-l-purple-500 hover:bg-purple-50/10',
                                                        row.flow_type === 'sale' && 'border-l-emerald-300 hover:border-l-emerald-500 hover:bg-emerald-50/10',
                                                        row.flow_type === 'purchase' && 'border-l-blue-300 hover:border-l-blue-500 hover:bg-blue-50/10',
                                                        row.flow_type === 'journal' && 'border-l-slate-200 hover:border-l-slate-400 hover:bg-slate-50/20',
                                                        isVoid && 'opacity-60 text-slate-400 bg-slate-50/30 line-through decoration-slate-350',
                                                        isExpanded && 'bg-indigo-50/30 border-l-indigo-400'
                                                    )}
                                                >
                                                    {/* Voucher */}
                                                    <td className="px-3 py-2 align-middle">
                                                        <div className="flex items-center gap-1">
                                                            <button
                                                                onClick={() => toggleExpand(row.voucher_no)}
                                                                title={isExpanded ? "Collapse journal" : "View journal"}
                                                                className={cn(
                                                                    'p-1 rounded transition-all shrink-0 hover:bg-indigo-50',
                                                                    isExpanded
                                                                        ? 'text-indigo-600 bg-indigo-50/50'
                                                                        : 'text-slate-400 hover:text-indigo-600'
                                                                )}
                                                            >
                                                                <BookOpen className="h-3.5 w-3.5" />
                                                            </button>
                                                            <span
                                                                className="font-mono text-[10px] font-semibold text-slate-700 bg-slate-100 border border-slate-200 px-1.5 py-0.5 rounded shadow-sm cursor-pointer"
                                                                title={row.voucher_no}
                                                                onClick={() => toggleExpand(row.voucher_no)}
                                                            >
                                                                {row.short_id}
                                                            </span>
                                                        </div>
                                                    </td>

                                                    {/* Time */}
                                                    <td className="px-3 py-2 align-middle text-slate-500 font-medium text-[11px] tabular-nums">
                                                        {row.raw_created_at ? (
                                                            (() => {
                                                                try {
                                                                    return new Date(row.raw_created_at).toLocaleTimeString('en-US', {
                                                                        hour: '2-digit',
                                                                        minute: '2-digit',
                                                                        hour12: true
                                                                    });
                                                                } catch (e) {
                                                                    return '—';
                                                                }
                                                            })()
                                                        ) : '—'}
                                                    </td>

                                                    {/* Transaction Type */}
                                                    <td className="px-3 py-2 align-middle">
                                                        {(() => {
                                                            const badge = getTransactionBadgeConfig(
                                                                row.voucher_no,
                                                                row.flow_type,
                                                                row.from_code || '',
                                                                row.from_name,
                                                                row.to_code || '',
                                                                row.to_name
                                                            );
                                                            const IconComponent = badge.Icon;
                                                            return (
                                                                <span className={cn(
                                                                    'inline-flex items-center gap-1 px-2 py-0.5 text-[9px] font-bold rounded-full border shadow-sm uppercase tracking-wide',
                                                                    badge.cls
                                                                )}>
                                                                    <IconComponent className="h-3 w-3 shrink-0" />
                                                                    {badge.label}
                                                                </span>
                                                            );
                                                        })()}
                                                    </td>

                                                    {/* From */}
                                                    <td className="px-3 py-2 align-middle font-semibold text-[11px] text-slate-800 uppercase tracking-tight truncate max-w-[180px]" title={row.from_name}>
                                                        {row.from_name}
                                                    </td>

                                                    {/* To */}
                                                    <td className="px-3 py-2 align-middle font-semibold text-[11px] text-slate-800 uppercase tracking-tight truncate max-w-[180px]" title={row.to_name}>
                                                        {row.to_name}
                                                    </td>

                                                    {/* Fuel */}
                                                    <td className="px-3 py-2 align-middle text-[11px] font-bold text-slate-600 uppercase">
                                                        {row.fuel_name || <span className="text-slate-350">—</span>}
                                                    </td>

                                                    {/* Quantity */}
                                                    <td className="px-3 py-2 align-middle text-right font-semibold text-slate-700 text-[11px] tabular-nums">
                                                        {row.quantity ? `${row.quantity.toLocaleString()} L` : <span className="text-slate-350">—</span>}
                                                    </td>

                                                    {/* Rate */}
                                                    <td className="px-3 py-2 align-middle text-right font-medium text-slate-700 text-[11px] tabular-nums">
                                                        {row.rate_per_unit ? row.rate_per_unit.toFixed(2) : <span className="text-slate-355">—</span>}
                                                    </td>

                                                    {/* Amount */}
                                                    <td className={cn(
                                                        "px-3 py-2 align-middle text-right font-bold text-xs tabular-nums tracking-tight",
                                                        row.flow_type === 'deposit' || row.flow_type === 'sale' ? 'text-emerald-700' :
                                                        row.flow_type === 'payment' ? 'text-rose-700' :
                                                        row.flow_type === 'transfer' ? 'text-purple-700' :
                                                        row.flow_type === 'purchase' ? 'text-blue-700' :
                                                        'text-slate-600',
                                                        isVoid && 'line-through opacity-60'
                                                    )}>
                                                        {row.amount > 0 ? row.amount.toLocaleString('en-PK') : <span className="text-slate-355">—</span>}
                                                    </td>

                                                    {/* Status */}
                                                    <td className="px-3 py-2 align-middle text-center">
                                                        {isVoid ? (
                                                            <span className="inline-flex items-center px-1.5 py-0.5 text-[8px] font-black bg-rose-50 text-rose-700 border border-rose-250/70 rounded uppercase tracking-wider">
                                                                Reversed
                                                            </span>
                                                        ) : (
                                                            <span className="inline-flex items-center px-1.5 py-0.5 text-[8px] font-black bg-slate-50 text-slate-500 border border-slate-200 rounded uppercase tracking-wider">
                                                                Posted
                                                            </span>
                                                        )}
                                                    </td>

                                                    {/* Actions */}
                                                    <td className="px-3 py-2 align-middle print:hidden text-right">
                                                        <div className="flex items-center justify-end gap-0.5">
                                                            <Button
                                                                variant="ghost" size="icon"
                                                                className="h-6 w-6 text-slate-400 hover:text-slate-900 hover:bg-slate-100"
                                                                title="View voucher (read-only)"
                                                                onClick={() => {
                                                                    if (row.type === 'sale' || row.type === 'purchase') {
                                                                        navigate(`/manage-transactions?edit=${row.voucher_no}&type=${row.type.toUpperCase()}`);
                                                                    } else {
                                                                        toast({
                                                                            title: 'View only',
                                                                            description: PHASE2_COMING_MESSAGE,
                                                                        });
                                                                    }
                                                                }}
                                                            >
                                                                <Edit2 className="h-3.5 w-3.5" />
                                                            </Button>
                                                            {!isVoid && (row.type === 'sale' || row.type === 'purchase') && (
                                                                <Button
                                                                    variant="ghost" size="icon"
                                                                    className="h-6 w-6 text-slate-400 hover:text-rose-600 hover:bg-rose-50"
                                                                    title="Reverse transaction"
                                                                    onClick={() => setReversalVoucherNo(row.voucher_no)}
                                                                >
                                                                    <RotateCcw className="h-3.5 w-3.5" />
                                                                </Button>
                                                            )}
                                                            {!isVoid && row.type !== 'sale' && row.type !== 'purchase' && role === 'admin' && (
                                                                <Button
                                                                    variant="ghost" size="icon"
                                                                    className="h-6 w-6 text-slate-400 hover:text-rose-600 hover:bg-rose-50"
                                                                    title="Reversal not available for this type yet"
                                                                    onClick={() => {
                                                                        toast({
                                                                            variant: 'destructive',
                                                                            title: 'Reversal unavailable',
                                                                            description: PHASE2_COMING_MESSAGE,
                                                                        });
                                                                    }}
                                                                >
                                                                    <RotateCcw className="h-3.5 w-3.5 opacity-40" />
                                                                </Button>
                                                            )}
                                                        </div>
                                                    </td>
                                                </tr>

                                                {/* ── Expandable journal drill-down ─────────── */}
                                                {isExpanded && (
                                                    <tr>
                                                        <td colSpan={11} className="px-4 py-3 bg-slate-50/50 border-t border-b border-slate-200">
                                                            <div className="max-w-4xl space-y-3">
                                                                {/* Remarks / Narration Section */}
                                                                <div className="bg-white border border-slate-200 rounded p-3 shadow-sm">
                                                                    <div className="text-[10px] font-bold text-slate-400 uppercase tracking-wider mb-1">
                                                                        Narration & Remarks
                                                                    </div>
                                                                    <div className="text-xs font-semibold text-slate-800 leading-relaxed">
                                                                        {row.remarks ? formatNarration(row.remarks, row) : <span className="text-slate-400 italic">No narration recorded for this transaction.</span>}
                                                                    </div>
                                                                    {row.fuel_name && row.quantity && (
                                                                        <div className="mt-2 pt-2 border-t border-dashed border-slate-100 flex gap-4 text-[10px] text-slate-500 font-medium">
                                                                            <div>
                                                                                <span className="font-bold text-slate-400 uppercase">Fuel:</span> {row.fuel_name}
                                                                            </div>
                                                                            <div>
                                                                                <span className="font-bold text-slate-400 uppercase">Qty:</span> {row.quantity.toLocaleString()} L
                                                                            </div>
                                                                            <div>
                                                                                <span className="font-bold text-slate-400 uppercase">Rate:</span> Rs {Number(row.rate_per_unit).toFixed(2)}
                                                                            </div>
                                                                            <div>
                                                                                <span className="font-bold text-slate-400 uppercase">Total:</span> Rs {Number(row.total_amount).toLocaleString('en-PK')}
                                                                            </div>
                                                                        </div>
                                                                    )}
                                                                </div>

                                                                {/* Journal Table */}
                                                                <div className="border border-indigo-200/80 rounded overflow-hidden shadow-sm">
                                                                    {/* Header */}
                                                                    <div className="bg-indigo-900 text-white px-3 py-1 flex items-center gap-2">
                                                                        <BookOpen className="h-3 w-3 text-indigo-300" />
                                                                        <span className="text-[9px] font-black uppercase tracking-widest text-indigo-100">
                                                                            Full Journal Ledger — {row.voucher_no}
                                                                        </span>
                                                                        <span className="ml-auto text-[9px] text-indigo-300">
                                                                            {drillEntries.length} lines
                                                                        </span>
                                                                    </div>

                                                                    {/* Journal entries table */}
                                                                    <table className="w-full text-xs">
                                                                        <thead>
                                                                            <tr className="bg-indigo-100 border-b border-indigo-200 text-[9px] font-black uppercase text-indigo-600">
                                                                                <th className="px-3 py-1.5 text-left w-16">Code</th>
                                                                                <th className="px-3 py-1.5 text-left">Account</th>
                                                                                <th className="px-3 py-1.5 text-left">Party</th>
                                                                                <th className="px-3 py-1.5 text-right text-emerald-600 w-28">Dr</th>
                                                                                <th className="px-3 py-1.5 text-right text-rose-600 w-28">Cr</th>
                                                                                <th className="px-3 py-1.5 text-center w-20">Type</th>
                                                                            </tr>
                                                                        </thead>
                                                                        <tbody className="bg-white divide-y divide-slate-50">
                                                                            {drillEntries.map((entry: any, idx: number) => {
                                                                                const isCash = CASH_BANK_CODES.includes(entry.accounts?.code);
                                                                                return (
                                                                                    <tr key={idx} className={isCash ? 'bg-emerald-50/20' : 'bg-white'}>
                                                                                        <td className="px-3 py-1.5 font-mono text-[10px] text-slate-400">
                                                                                            {entry.accounts?.code || '—'}
                                                                                        </td>
                                                                                        <td className="px-3 py-1.5 font-bold text-slate-700 uppercase text-[10px]">
                                                                                            {entry.accounts?.name || '—'}
                                                                                        </td>
                                                                                        <td className="px-3 py-1.5 text-slate-400 text-[10px]">
                                                                                            {entry.party?.name || <span className="text-slate-200">—</span>}
                                                                                        </td>
                                                                                        <td className="px-3 py-1 text-right font-bold text-emerald-700 tabular-nums">
                                                                                            {Number(entry.debit_amount) > 0
                                                                                                ? Number(entry.debit_amount).toLocaleString('en-PK')
                                                                                                : <span className="text-slate-200">—</span>}
                                                                                        </td>
                                                                                        <td className="px-3 py-1 text-right font-bold text-rose-700 tabular-nums">
                                                                                            {Number(entry.credit_amount) > 0
                                                                                                ? Number(entry.credit_amount).toLocaleString('en-PK')
                                                                                                : <span className="text-slate-200">—</span>}
                                                                                        </td>
                                                                                        <td className="px-3 py-1.5 text-center">
                                                                                            {isCash
                                                                                                ? <span className="px-1.5 py-0.5 bg-emerald-600 text-white text-[8px] font-black rounded-sm">CASH/BANK</span>
                                                                                                : <span className="text-slate-300 text-[9px]">ledger</span>}
                                                                                        </td>
                                                                                    </tr>
                                                                                );
                                                                            })}
                                                                        </tbody>
                                                                        <tfoot className="bg-indigo-100 border-t border-indigo-200 text-[9px] font-black uppercase text-indigo-600">
                                                                            <tr>
                                                                                <td colSpan={3} className="px-3 py-1.5 text-right">
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
                                                            </div>
                                                        </td>
                                                    </tr>
                                                )}
                                            </Fragment>
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

            <ReversalModal
                voucherNo={reversalVoucherNo}
                isOpen={!!reversalVoucherNo}
                onClose={() => setReversalVoucherNo(null)}
            />
        </DashboardLayout>
    );
}
