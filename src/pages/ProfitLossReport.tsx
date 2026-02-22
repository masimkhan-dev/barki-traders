import { useState, useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { supabase } from '@/integrations/supabase/client';
import { formatPKR, formatNumber } from '@/lib/format';
import { Button } from '@/components/ui/button';
import { Printer, Loader2, Landmark } from 'lucide-react';
import { cn } from '@/lib/utils';

export default function ProfitLossReport() {
    const today = new Date();
    const firstDay = new Date(today.getFullYear(), today.getMonth(), 1).toISOString().split('T')[0];
    const currentDay = today.toISOString().split('T')[0];

    const [startDate, setStartDate] = useState<string>(firstDay);
    const [endDate, setEndDate] = useState<string>(currentDay);

    const { data: rawData, isLoading, error } = useQuery({
        queryKey: ['pnl-v2-rpc', startDate, endDate],
        queryFn: async () => {
            const { data, error } = await (supabase.rpc as any)('get_profit_loss_v11', {
                p_start_date: startDate,
                p_end_date: endDate
            });

            if (error) throw error;
            return data as { section: string, account_name: string, amount: number }[];
        }
    });

    const report = useMemo(() => {
        if (!rawData) return null;

        const income = rawData.filter(r => r.section === 'Income' || r.section === 'Revenue');
        const directCosts = rawData.filter(r => r.section === 'Direct Costs' || r.section === 'COGS');
        const operatingExpenses = rawData.filter(r => r.section === 'Expenses' || r.section === 'Operating Expenses');
        const otherIncome = rawData.filter(r => r.section === 'Other Income');
        const otherExpense = rawData.filter(r => r.section === 'Other Expense' || r.section === 'Other Expenses');

        const totalRevenue = income.reduce((sum, r) => sum + Number(r.amount), 0);
        const totalDirectCosts = directCosts.reduce((sum, r) => sum + Number(r.amount), 0);
        const grossProfit = totalRevenue - totalDirectCosts;

        const totalOperatingExpenses = operatingExpenses.reduce((sum, r) => sum + Number(r.amount), 0);
        const netOperatingIncome = grossProfit - totalOperatingExpenses;

        const totalOtherIncome = otherIncome.reduce((sum, r) => sum + Number(r.amount), 0);
        const totalOtherExpense = otherExpense.reduce((sum, r) => sum + Number(r.amount), 0);

        const netIncome = netOperatingIncome + totalOtherIncome - totalOtherExpense;

        return {
            income,
            directCosts,
            operatingExpenses,
            otherIncome,
            otherExpense,
            totalRevenue,
            totalDirectCosts,
            grossProfit,
            totalOperatingExpenses,
            netOperatingIncome,
            totalOtherIncome,
            totalOtherExpense,
            netIncome
        };
    }, [rawData]);

    if (error) {
        return (
            <DashboardLayout>
                <div className="max-w-4xl mx-auto p-8">
                    <div className="bg-red-50 p-6 rounded-lg border border-red-200">
                        <p className="text-red-700 font-bold">Error Loading Report: {(error as Error).message}</p>
                    </div>
                </div>
            </DashboardLayout>
        );
    }

    return (
        <DashboardLayout>
            <div className="max-w-5xl mx-auto pb-20 print:p-0">
                <div className="sticky-filter-bar print:hidden px-4 backdrop-blur-md bg-white/80 border-b border-slate-200">
                    <div className="max-w-5xl mx-auto flex flex-col lg:flex-row items-start lg:items-center justify-between gap-6 py-4">
                        <div className="report-header mb-0">
                            <div className="flex items-center gap-3">
                                <div className="bg-slate-900 p-2 rounded-lg text-white">
                                    <Landmark className="h-6 w-6" />
                                </div>
                                <div>
                                    <h1 className="report-title text-2xl font-black tracking-tight text-slate-900 uppercase">Profit & Loss Report</h1>
                                    <p className="report-subtitle text-slate-500 font-bold uppercase tracking-[0.2em] text-[10px]">Corporate Accounting Format</p>
                                </div>
                            </div>
                        </div>

                        <div className="flex flex-wrap items-center gap-4 bg-white p-2 border border-slate-200 shadow-sm rounded-xl">
                            <div className="flex items-center gap-4 px-2">
                                <div className="flex flex-col">
                                    <label className="text-[9px] font-black uppercase text-slate-400 mb-1">From Date</label>
                                    <input type="date" value={startDate} onChange={e => setStartDate(e.target.value)} className="h-9 px-3 border border-slate-200 rounded-lg font-bold text-xs" />
                                </div>
                                <div className="flex flex-col">
                                    <label className="text-[9px] font-black uppercase text-slate-400 mb-1">To Date</label>
                                    <input type="date" value={endDate} onChange={e => setEndDate(e.target.value)} className="h-9 px-3 border border-slate-200 rounded-lg font-bold text-xs" />
                                </div>
                            </div>
                            <Button
                                className="h-10 px-6 rounded-lg bg-slate-900 hover:bg-slate-800 text-white font-bold uppercase text-[10px] tracking-widest gap-2"
                                onClick={() => window.print()}
                            >
                                <Printer className="h-4 w-4" /> Print
                            </Button>
                        </div>
                    </div>
                </div>

                <div className="px-4 space-y-8 mt-8">
                    {isLoading || !report ? (
                        <div className="flex flex-col items-center justify-center min-h-[40vh] gap-4">
                            <Loader2 className="h-10 w-10 animate-spin text-slate-300" />
                            <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-400">Calculating Finances...</span>
                        </div>
                    ) : (
                        <div className="bg-white border text-sm border-slate-200 rounded-xl overflow-hidden shadow-sm">
                            <table className="w-full border-collapse">
                                <thead>
                                    <tr className="bg-slate-50 border-b border-slate-200">
                                        <th className="text-left px-6 py-3 text-[10px] font-black uppercase tracking-widest text-slate-500">Account</th>
                                        <th className="text-right px-6 py-3 text-[10px] font-black uppercase tracking-widest text-slate-500">Total (PKR)</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {/* REVENUE */}
                                    <tr className="bg-slate-50"><td colSpan={2} className="px-6 py-2 font-black text-slate-900 uppercase text-xs tracking-widest">Revenue</td></tr>
                                    {report.income.map((item, i) => (
                                        <tr key={i} className="border-b border-slate-50 hover:bg-slate-50 transition-colors">
                                            <td className="px-10 py-2.5 font-bold uppercase text-slate-600 text-xs">{item.account_name}</td>
                                            <td className="text-right px-6 py-2.5 font-bold tabular-nums text-slate-800">{formatNumber(item.amount)}</td>
                                        </tr>
                                    ))}
                                    <tr className="font-black border-b border-slate-200">
                                        <td className="px-10 py-3 uppercase text-slate-700 text-xs tracking-widest">Total Revenue</td>
                                        <td className="text-right px-6 py-3 tabular-nums">{formatNumber(report.totalRevenue)}</td>
                                    </tr>

                                    {/* DIRECT COSTS */}
                                    <tr className="bg-slate-50"><td colSpan={2} className="px-6 py-2 font-black text-slate-900 uppercase text-xs tracking-widest">Direct Costs</td></tr>
                                    {report.directCosts.map((item, i) => (
                                        <tr key={i} className="border-b border-slate-50 hover:bg-slate-50 transition-colors">
                                            <td className="px-10 py-2.5 font-bold uppercase text-slate-600 text-xs">{item.account_name}</td>
                                            <td className="text-right px-6 py-2.5 font-bold tabular-nums text-rose-700">({formatNumber(item.amount)})</td>
                                        </tr>
                                    ))}
                                    <tr className="font-black border-b border-slate-200">
                                        <td className="px-10 py-3 uppercase text-slate-700 text-xs tracking-widest">Total Direct Costs</td>
                                        <td className="text-right px-6 py-3 tabular-nums text-rose-700">({formatNumber(report.totalDirectCosts)})</td>
                                    </tr>

                                    {/* GROSS PROFIT */}
                                    <tr className="bg-slate-100 font-black border-b-2 border-slate-300">
                                        <td className="px-6 py-4 uppercase text-emerald-800 text-xs tracking-widest">Gross Profit</td>
                                        <td className="text-right px-6 py-4 text-base tabular-nums text-emerald-800">{formatPKR(report.grossProfit)}</td>
                                    </tr>

                                    {/* OPERATING EXPENSES */}
                                    <tr className="bg-slate-50"><td colSpan={2} className="px-6 py-2 font-black text-slate-900 uppercase text-xs tracking-widest">Expenses</td></tr>
                                    {report.operatingExpenses.map((item, i) => (
                                        <tr key={i} className="border-b border-slate-50 hover:bg-slate-50 transition-colors">
                                            <td className="px-10 py-2.5 font-bold uppercase text-slate-600 text-xs">{item.account_name}</td>
                                            <td className="text-right px-6 py-2.5 font-bold tabular-nums text-rose-700">({formatNumber(item.amount)})</td>
                                        </tr>
                                    ))}
                                    <tr className="font-black border-b border-slate-200">
                                        <td className="px-10 py-3 uppercase text-slate-700 text-xs tracking-widest">Total Expenses</td>
                                        <td className="text-right px-6 py-3 tabular-nums text-rose-700">({formatNumber(report.totalOperatingExpenses)})</td>
                                    </tr>

                                    {/* NET OPERATING INCOME */}
                                    <tr className="bg-slate-100 font-black border-b-2 border-slate-300">
                                        <td className="px-6 py-4 uppercase text-slate-900 text-xs tracking-widest">Net Operating Income</td>
                                        <td className="text-right px-6 py-4 text-base tabular-nums">{formatPKR(report.netOperatingIncome)}</td>
                                    </tr>

                                    {/* OTHER INCOME / EXPENSE */}
                                    {(report.totalOtherIncome > 0 || report.totalOtherExpense > 0) && (
                                        <>
                                            <tr className="bg-slate-50"><td colSpan={2} className="px-6 py-2 font-black text-slate-900 uppercase text-xs tracking-widest">Other Income & Expenses</td></tr>
                                            {report.otherIncome.map((item, i) => (
                                                <tr key={`oi-${i}`} className="border-b border-slate-50 hover:bg-slate-50 transition-colors">
                                                    <td className="px-10 py-2.5 font-bold uppercase text-slate-600 text-xs">{item.account_name}</td>
                                                    <td className="text-right px-6 py-2.5 font-bold tabular-nums text-slate-800">{formatNumber(item.amount)}</td>
                                                </tr>
                                            ))}
                                            {report.otherExpense.map((item, i) => (
                                                <tr key={`oe-${i}`} className="border-b border-slate-50 hover:bg-slate-50 transition-colors">
                                                    <td className="px-10 py-2.5 font-bold uppercase text-slate-600 text-xs">{item.account_name}</td>
                                                    <td className="text-right px-6 py-2.5 font-bold tabular-nums text-rose-700">({formatNumber(item.amount)})</td>
                                                </tr>
                                            ))}
                                        </>
                                    )}

                                </tbody>
                                <tfoot>
                                    <tr className={cn(
                                        "font-black text-xl",
                                        report.netIncome >= 0 ? "bg-slate-900 text-white" : "bg-rose-900 text-white"
                                    )}>
                                        <td className="px-6 py-6 uppercase tracking-[0.2em]">Net Income</td>
                                        <td className="text-right px-6 py-6 tabular-nums">{formatPKR(report.netIncome)}</td>
                                    </tr>
                                </tfoot>
                            </table>
                        </div>
                    )}
                </div>
            </div>
        </DashboardLayout>
    );
}
