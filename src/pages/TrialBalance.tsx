
import { useState, useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { supabase } from '@/integrations/supabase/client';
import { formatPKR } from '@/lib/format';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import {
    Printer,
    FileSpreadsheet,
    Calculator,
    CheckCircle2,
    AlertCircle,
    ArrowUpRight,
    ArrowDownLeft,
    Search,
    Loader2
} from 'lucide-react';
import { cn } from '@/lib/utils';
import React from 'react';

export default function TrialBalance() {
    const today = new Date();
    const firstDayOfYear = new Date(today.getFullYear(), 0, 1);

    const [startDate, setStartDate] = useState<string>(firstDayOfYear.toISOString().split('T')[0]);
    const [endDate, setEndDate] = useState<string>(today.toISOString().split('T')[0]);

    const { data: trialData, isLoading } = useQuery({
        queryKey: ['trial-balance-pro', startDate, endDate],
        queryFn: async () => {
            const { data, error } = await (supabase.rpc as any)('get_trial_balance_v2', {
                p_start_date: startDate,
                p_end_date: endDate
            });
            if (error) throw error;
            return data as any[];
        }
    });

    // Advanced Grouping Logic
    const groupedData = useMemo(() => {
        if (!trialData) return null;

        const categories = {
            'ASSETS': [] as any[],
            'LIABILITIES': [] as any[],
            'EQUITY': [] as any[],
            'INCOME': [] as any[],
            'EXPENSES': [] as any[]
        };

        trialData.forEach(row => {
            const type = String(row.account_type || '').toUpperCase();
            if (type.includes('ASSET')) categories.ASSETS.push(row);
            else if (type.includes('LIABILITY')) categories.LIABILITIES.push(row);
            else if (type.includes('EQUITY')) categories.EQUITY.push(row);
            else if (type.includes('INCOME') || type.includes('REVENUE')) categories.INCOME.push(row);
            else if (type.includes('EXPENSE')) categories.EXPENSES.push(row);
            else categories.ASSETS.push(row); // Fallback
        });

        return categories;
    }, [trialData]);

    const totals = useMemo(() => {
        return trialData?.reduce((acc: any, curr: any) => ({
            opening: acc.opening + (Number(curr.opening_balance) || 0),
            debit: acc.debit + (Number(curr.debit_total) || 0),
            credit: acc.credit + (Number(curr.credit_total) || 0),
            movement: acc.movement + (Number(curr.net_movement) || 0),
            closing_dr: acc.closing_dr + (Number(curr.debit_balance) || 0),
            closing_cr: acc.closing_cr + (Number(curr.credit_balance) || 0)
        }), { opening: 0, debit: 0, credit: 0, movement: 0, closing_dr: 0, closing_cr: 0 }) ||
            { opening: 0, debit: 0, credit: 0, movement: 0, closing_dr: 0, closing_cr: 0 };
    }, [trialData]);

    const isBalanced = Math.abs(totals.closing_dr - totals.closing_cr) < 1;

    return (

        <DashboardLayout>
            <div className="max-w-full mx-auto pb-20 print:p-0 overflow-hidden">

                {/* STICKY FILTER BAR */}
                <div className="sticky-filter-bar print:hidden px-4">
                    <div className="max-w-7xl mx-auto flex flex-wrap items-center justify-between gap-4">
                        <div className="report-header mb-0">
                            <h1 className="report-title">Naveed Musazai</h1>
                            <p className="report-subtitle">Advanced Audit Trial Balance / Multi-Period Engine</p>
                        </div>

                        <div className="flex flex-wrap items-center gap-3 bg-slate-50 p-2 border border-slate-200 rounded-sm">
                            <div className="flex flex-col">
                                <label className="text-[9px] font-bold uppercase text-slate-500 mb-1">From</label>
                                <input type="date" value={startDate} onChange={e => setStartDate(e.target.value)} className="h-8 px-2 border border-slate-300 rounded-none font-bold text-xs" />
                            </div>
                            <div className="flex flex-col">
                                <label className="text-[9px] font-bold uppercase text-slate-500 mb-1">To</label>
                                <input type="date" value={endDate} onChange={e => setEndDate(e.target.value)} className="h-8 px-2 border border-slate-300 rounded-none font-bold text-xs" />
                            </div>
                            <Button variant="outline" size="icon" className="h-8 w-8 rounded-none border-slate-300 ml-2" onClick={() => window.print()} title="Print Trial Balance">
                                <Printer className="h-3.5 w-3.5" />
                            </Button>
                        </div>
                    </div>
                </div>

                <div className="px-4 space-y-6">
                    {/* SUMMARY BOXES */}
                    <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
                        <div className="summary-card">
                            <span className="summary-label">Total Assets & Expenses (Dr)</span>
                            <span className="summary-value text-assets">{formatPKR(totals.closing_dr)}</span>
                        </div>
                        <div className="summary-card">
                            <span className="summary-label">Total Liabilities, Equity & Income (Cr)</span>
                            <span className="summary-value text-liabilities">{formatPKR(totals.closing_cr)}</span>
                        </div>
                        <div className={cn(
                            "summary-card border-l-4",
                            isBalanced ? "border-l-emerald-500 bg-emerald-50/20" : "border-l-rose-500 bg-rose-50/20"
                        )}>
                            <span className="summary-label">{isBalanced ? "Audit Status: CLEAN" : "Audit Status: MISMATCHED"}</span>
                            <span className={cn("summary-value", isBalanced ? "text-assets" : "text-rose-700")}>
                                {isBalanced ? "TRIAL BALANCE MATCHED" : `OUT BY: ${formatPKR(Math.abs(totals.closing_dr - totals.closing_cr))}`}
                            </span>
                        </div>
                    </div>

                    {/* TRIAL BALANCE TABLE */}
                    <div className="overflow-x-auto border border-slate-300 shadow-sm rounded-sm">
                        <table className="ledger-table !text-[10px] w-full min-w-[1000px]">
                            <thead>
                                <tr className="bg-slate-900 !border-slate-900 text-[9px] uppercase tracking-tighter">
                                    <th className="!text-white w-10 center-align py-2">S.No</th>
                                    <th className="!text-white text-left pl-4">Account Description</th>
                                    <th className="!text-white right-align w-32 bg-slate-800">Opening Balance</th>
                                    <th className="!text-white right-align w-32">Debit (In)</th>
                                    <th className="!text-white right-align w-32">Credit (Out)</th>
                                    <th className="!text-white right-align w-32 bg-slate-800">Net Movement</th>
                                    <th className="!text-white right-align w-32 text-emerald-400">Closing Dr</th>
                                    <th className="!text-white right-align w-32 text-rose-400">Closing Cr</th>
                                </tr>
                            </thead>
                            <tbody>
                                {isLoading ? (
                                    <tr>
                                        <td colSpan={8} className="py-24 bg-slate-50/50">
                                            <div className="flex flex-col items-center justify-center gap-4">
                                                <Loader2 className="h-8 w-8 animate-spin text-slate-400" />
                                                <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-500">Auditing Ledger Balances...</span>
                                            </div>
                                        </td>
                                    </tr>
                                ) : groupedData ? (
                                    (() => {
                                        let sn = 1;
                                        return Object.entries(groupedData).map(([category, accounts]) => (
                                            accounts.length > 0 && (
                                                <React.Fragment key={category}>
                                                    <tr className="bg-slate-200/50 font-black border-y border-slate-300">
                                                        <td colSpan={8} className="px-4 py-1.5 text-[10px] uppercase font-black tracking-[0.1em] text-slate-700 bg-slate-200">{category}</td>
                                                    </tr>
                                                    {accounts.map((row, idx) => (
                                                        <tr key={idx} className="hover:bg-slate-50 transition-colors border-b border-slate-100">
                                                            <td className="center-align text-slate-400 font-bold">{sn++}</td>
                                                            <td className="px-4 py-1">
                                                                <div className="flex items-center gap-2">
                                                                    <span className="text-[8px] font-black bg-slate-100 px-1 border border-slate-200 rounded-sm text-slate-500">{row.account_code || 'N/A'}</span>
                                                                    <span className="font-bold text-slate-800 uppercase text-[10px]">{row.account_name}</span>
                                                                </div>
                                                            </td>
                                                            {/* OPENING */}
                                                            <td className="right-align px-4 font-bold bg-slate-50/50 text-slate-600">
                                                                {Number(row.opening_balance) !== 0 ? Math.abs(row.opening_balance).toLocaleString() : '-'}
                                                                <span className="text-[7px] ml-1">{Number(row.opening_balance) > 0 ? 'Dr' : Number(row.opening_balance) < 0 ? 'Cr' : ''}</span>
                                                            </td>
                                                            {/* PERIOD DR */}
                                                            <td className="right-align px-4 text-slate-500">
                                                                {Number(row.debit_total) !== 0 ? Math.abs(row.debit_total).toLocaleString() : '-'}
                                                            </td>
                                                            {/* PERIOD CR */}
                                                            <td className="right-align px-4 text-slate-500 border-r border-slate-100">
                                                                {Number(row.credit_total) !== 0 ? Math.abs(row.credit_total).toLocaleString() : '-'}
                                                            </td>
                                                            {/* MOVEMENT */}
                                                            <td className={cn(
                                                                "right-align px-4 font-black bg-slate-50/50",
                                                                Number(row.net_movement) > 0 ? "text-assets" : Number(row.net_movement) < 0 ? "text-liabilities" : "text-slate-300"
                                                            )}>
                                                                {Number(row.net_movement) !== 0 ? Math.abs(row.net_movement).toLocaleString() : '-'}
                                                            </td>
                                                            {/* CLOSING DR */}
                                                            <td className="right-align px-4 font-black text-emerald-700 border-l border-slate-100 bg-emerald-50/10">
                                                                {Number(row.debit_balance) > 0 ? Math.abs(row.debit_balance).toLocaleString() : '-'}
                                                            </td>
                                                            {/* CLOSING CR */}
                                                            <td className="right-align px-4 font-black text-rose-700 bg-rose-50/10">
                                                                {Number(row.credit_balance) > 0 ? Math.abs(row.credit_balance).toLocaleString() : '-'}
                                                            </td>
                                                        </tr>
                                                    ))}
                                                </React.Fragment>
                                            )
                                        ));
                                    })()
                                ) : (
                                    <tr><td colSpan={8} className="py-24 center-align italic text-slate-300">No data available for selected period</td></tr>
                                )}
                            </tbody>
                            <tfoot>
                                <tr className="bg-slate-900 text-white font-black text-[11px] border-t-2 border-slate-500">
                                    <td colSpan={2} className="px-4 py-4 right-align text-[9px] uppercase tracking-widest text-slate-400">Consolidated Trial Totals:</td>
                                    <td className="px-4 py-4 right-align bg-slate-800">{totals.opening.toLocaleString()}</td>
                                    <td className="px-4 py-4 right-align">{totals.debit.toLocaleString()}</td>
                                    <td className="px-4 py-4 right-align">{totals.credit.toLocaleString()}</td>
                                    <td className="px-4 py-4 right-align bg-slate-800">{totals.movement.toLocaleString()}</td>
                                    <td className="px-4 py-4 right-align text-emerald-400 text-sm border-l border-white/5">{formatPKR(totals.closing_dr)}</td>
                                    <td className="px-4 py-4 right-align text-rose-400 text-sm">{formatPKR(totals.closing_cr)}</td>
                                </tr>
                            </tfoot>
                        </table>
                    </div>

                </div>
            </div>
        </DashboardLayout>

    );
}
