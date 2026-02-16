
import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { supabase } from '@/integrations/supabase/client';
import { formatPKR, formatNumber } from '@/lib/format';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Printer, TrendingDown, Landmark, Minus, Plus, Loader2 } from 'lucide-react';

import { cn } from '@/lib/utils';

export default function ProfitLossReport() {
    // Default to current month
    const today = new Date();
    const firstDay = new Date(today.getFullYear(), today.getMonth(), 1).toISOString().split('T')[0];
    const currentDay = today.toISOString().split('T')[0];

    const [startDate, setStartDate] = useState<string>(firstDay);
    const [endDate, setEndDate] = useState<string>(currentDay);

    const { data: reportData, isLoading, error } = useQuery({
        queryKey: ['pnl-rpc-v2', startDate, endDate],
        queryFn: async () => {
            // CALL THE CORRECT SQL FUNCTION (V11 NIL COMPATIBLE)
            const { data, error } = await (supabase.rpc as any)('get_profit_loss_v11', {
                p_start_date: startDate,
                p_end_date: endDate
            });

            if (error) throw error;

            // Transform the data for the UI
            const rows = data as { section: string, account_name: string, amount: number }[];

            const income = rows.filter(r => r.section === 'Income');
            const directCosts = rows.filter(r => r.section === 'Direct Costs');
            const expenses = rows.filter(r => r.section === 'Expenses' || r.section === 'Operating Expenses');

            const totalIncome = income.reduce((sum, r) => sum + Number(r.amount), 0);
            const totalCOGS = directCosts.reduce((sum, r) => sum + Number(r.amount), 0);
            const totalExpenses = expenses.reduce((sum, r) => sum + Number(r.amount), 0);

            return {
                income,
                directCosts,
                expenses,
                totalIncome,
                totalCOGS,
                totalExpenses,
                grossProfit: totalIncome - totalCOGS,
                netProfit: totalIncome - totalCOGS - totalExpenses
            };
        }
    });

    if (error) {
        return (
            <DashboardLayout>
                <div className="max-w-4xl mx-auto space-y-8 p-8">
                    <div className="bg-red-50 border border-red-200 rounded-lg p-6">
                        <h3 className="font-bold text-red-800 mb-1">Error Loading Report</h3>
                        <p className="text-red-700 text-sm">{(error as Error).message}</p>
                    </div>
                </div>
            </DashboardLayout>
        )
    }

    return (


        <DashboardLayout>
            <div className="max-w-5xl mx-auto pb-20 print:p-0">

                {/* STICKY FILTER BAR */}
                <div className="sticky-filter-bar print:hidden px-4 backdrop-blur-md bg-white/80 border-b border-slate-200">
                    <div className="max-w-5xl mx-auto flex flex-col lg:flex-row items-start lg:items-center justify-between gap-6 py-4">
                        <div className="report-header mb-0">
                            <div className="flex items-center gap-3">
                                <div className="bg-slate-900 p-2 rounded-lg text-white">
                                    <Landmark className="h-6 w-6" />
                                </div>
                                <div>
                                    <h1 className="report-title text-2xl font-black tracking-tight text-slate-900">Naveed Musazai</h1>
                                    <p className="report-subtitle text-slate-500 font-bold uppercase tracking-[0.2em] text-[10px]">Consolidated Financial Performance Review</p>
                                </div>
                            </div>
                        </div>

                        <div className="flex flex-wrap items-center gap-4 bg-white p-2 border border-slate-200 shadow-sm rounded-xl">
                            <div className="flex items-center gap-4 px-2">
                                <div className="flex flex-col">
                                    <label className="text-[9px] font-black uppercase text-slate-400 mb-1">Period From</label>
                                    <input type="date" value={startDate} onChange={e => setStartDate(e.target.value)} className="h-9 px-3 border border-slate-200 rounded-lg font-bold text-xs outline-none focus:ring-2 focus:ring-slate-900/10 transition-all" />
                                </div>
                                <div className="flex flex-col">
                                    <label className="text-[9px] font-black uppercase text-slate-400 mb-1">Period To</label>
                                    <input type="date" value={endDate} onChange={e => setEndDate(e.target.value)} className="h-9 px-3 border border-slate-200 rounded-lg font-bold text-xs outline-none focus:ring-2 focus:ring-slate-900/10 transition-all" />
                                </div>
                            </div>
                            <div className="h-10 w-[1px] bg-slate-200 hidden md:block"></div>
                            <Button
                                variant="default"
                                className="h-10 px-6 rounded-lg bg-slate-900 hover:bg-slate-800 text-white font-bold uppercase text-[10px] tracking-widest gap-2"
                                onClick={() => window.print()}
                            >
                                <Printer className="h-4 w-4" /> Print Statement
                            </Button>
                        </div>
                    </div>
                </div>

                <div className="px-4 space-y-8 mt-8 pb-20">
                    {isLoading ? (
                        <div className="flex flex-col items-center justify-center min-h-[60vh] gap-4">
                            <Loader2 className="h-10 w-10 animate-spin text-slate-300" />
                            <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-400">Analyzing Financial Performance...</span>
                        </div>
                    ) : (
                        <>
                            {/* PREMIUM KPI DASHBOARD */}
                            <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
                                <div className="group relative bg-white border border-slate-200 p-5 rounded-2xl shadow-sm hover:shadow-md transition-all duration-300">
                                    <div className="absolute top-4 right-4 bg-emerald-50 text-emerald-600 p-1.5 rounded-full">
                                        <Plus className="h-4 w-4" />
                                    </div>
                                    <span className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Gross Revenue</span>
                                    <span className="block text-2xl font-black text-slate-900 tracking-tighter">{formatPKR(reportData?.totalIncome || 0)}</span>
                                    <div className="mt-3 flex items-center gap-2">
                                        <span className="h-1 w-full bg-slate-100 rounded-full overflow-hidden">
                                            <span className="block h-full bg-emerald-500 w-[100%]"></span>
                                        </span>
                                    </div>
                                </div>

                                <div className="group relative bg-white border border-slate-200 p-5 rounded-2xl shadow-sm hover:shadow-md transition-all duration-300">
                                    <div className="absolute top-4 right-4 bg-rose-50 text-rose-600 p-1.5 rounded-full">
                                        <Minus className="h-4 w-4" />
                                    </div>
                                    <span className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Direct Costs</span>
                                    <span className="block text-2xl font-black text-slate-900 tracking-tighter">{formatPKR(reportData?.totalCOGS || 0)}</span>
                                    <div className="mt-3 flex items-center gap-2">
                                        <span className="h-1 w-full bg-slate-100 rounded-full overflow-hidden">
                                            <span
                                                className="block h-full bg-rose-400"
                                                style={{ width: `${Math.min(((reportData?.totalCOGS || 0) / (reportData?.totalIncome || 1)) * 100, 100)}%` }}
                                            ></span>
                                        </span>
                                    </div>
                                </div>

                                <div className="group relative bg-white border border-slate-200 p-5 rounded-2xl shadow-sm hover:shadow-md transition-all duration-300">
                                    <div className="absolute top-4 right-4 bg-blue-50 text-blue-600 p-1.5 rounded-full">
                                        <TrendingDown className="h-4 w-4" />
                                    </div>
                                    <span className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Gross Margin</span>
                                    <div className="flex items-baseline gap-2">
                                        <span className="block text-2xl font-black text-slate-900 tracking-tighter">{formatPKR(reportData?.grossProfit || 0)}</span>
                                        <span className="text-xs font-bold text-slate-500">({((reportData?.grossProfit || 0) / (reportData?.totalIncome || 1) * 100).toFixed(1)}%)</span>
                                    </div>
                                    <div className="mt-3 flex items-center gap-2">
                                        <span className="h-1 w-full bg-slate-100 rounded-full overflow-hidden">
                                            <span
                                                className="block h-full bg-blue-500"
                                                style={{ width: `${Math.min(((reportData?.grossProfit || 0) / (reportData?.totalIncome || 1)) * 100, 100)}%` }}
                                            ></span>
                                        </span>
                                    </div>
                                </div>

                                <div className={cn(
                                    "group relative overflow-hidden p-5 rounded-2xl shadow-sm transition-all duration-300 border",
                                    (reportData?.netProfit || 0) >= 0
                                        ? "bg-slate-900 border-slate-900 text-white shadow-emerald-900/10"
                                        : "bg-rose-900 border-rose-950 text-white"
                                )}>
                                    <div className="absolute -bottom-4 -right-4 opacity-10">
                                        <Landmark className="h-24 w-24" />
                                    </div>
                                    <span className="block text-[10px] font-black text-slate-400 uppercase tracking-widest mb-2">Net Performance</span>
                                    <span className="block text-2xl font-black tracking-tighter drop-shadow-sm">
                                        {formatPKR(reportData?.netProfit || 0)}
                                    </span>
                                    <div className="mt-4">
                                        <div className="inline-flex items-center px-2 py-0.5 rounded text-[9px] font-black uppercase tracking-widest bg-white/10 backdrop-blur-sm">
                                            {(reportData?.netProfit || 0) >= 0 ? "Surplus Position" : "Deficit Position"}
                                        </div>
                                    </div>
                                </div>
                            </div>

                            {/* DETAILED STATEMENT */}
                            <div className="bg-white border-x border-t border-slate-200 rounded-t-2xl overflow-hidden shadow-sm">
                                <table className="w-full border-collapse">
                                    <thead>
                                        <tr className="bg-slate-50 border-b border-slate-200">
                                            <th className="text-left px-6 py-4 text-[11px] font-black uppercase tracking-widest text-slate-500 w-2/3">Account Classification & Particulars</th>
                                            <th className="right-align px-6 py-4 text-[11px] font-black uppercase tracking-widest text-slate-500">Amount (PKR)</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {/* INCOME SECTION */}
                                        <tr className="bg-emerald-50/30">
                                            <td colSpan={2} className="px-6 py-3">
                                                <div className="flex items-center gap-2">
                                                    <div className="h-6 w-1 bg-emerald-500 rounded-full"></div>
                                                    <span className="text-[10px] font-black uppercase tracking-[0.2em] text-emerald-800">Operational Income & Sales Revenue</span>
                                                </div>
                                            </td>
                                        </tr>
                                        {reportData?.income.map((item, i) => (
                                            <tr key={i} className="group hover:bg-slate-50 border-b border-slate-100 transition-colors">
                                                <td className="px-10 py-3.5">
                                                    <div className="flex items-center gap-3">
                                                        <div className="h-1.5 w-1.5 rounded-full bg-slate-200 group-hover:bg-emerald-500 transition-all"></div>
                                                        <span className="font-bold text-slate-700 uppercase pnl-text">{item.account_name}</span>
                                                    </div>
                                                </td>
                                                <td className="right-align px-6 py-3.5 num-audit font-black text-slate-800 text-sm">
                                                    {formatNumber(item.amount)}
                                                </td>
                                            </tr>
                                        ))}
                                        <tr className="bg-white font-black border-b-2 border-slate-200">
                                            <td className="px-6 py-4 text-[11px] uppercase tracking-widest font-black text-slate-500">Total Operational Revenue</td>
                                            <td className="right-align px-6 py-4 text-xl num-audit text-emerald-600">
                                                <span className="text-xs mr-2 text-slate-300">PKR</span>
                                                {formatNumber(reportData?.totalIncome || 0)}
                                            </td>
                                        </tr>

                                        {/* DIRECT COSTS SECTION */}
                                        <tr className="bg-rose-50/30">
                                            <td colSpan={2} className="px-6 py-3">
                                                <div className="flex items-center gap-2">
                                                    <div className="h-6 w-1 bg-rose-500 rounded-full"></div>
                                                    <span className="text-[10px] font-black uppercase tracking-[0.2em] text-rose-800">Direct Operating Costs (COGS)</span>
                                                </div>
                                            </td>
                                        </tr>
                                        {reportData?.directCosts.map((item, i) => (
                                            <tr key={i} className="group hover:bg-slate-50 border-b border-slate-100 transition-colors">
                                                <td className="px-10 py-3.5">
                                                    <div className="flex items-center gap-3">
                                                        <div className="h-1.5 w-1.5 rounded-full bg-slate-200 group-hover:bg-rose-500 transition-all"></div>
                                                        <span className="font-bold text-slate-700 uppercase pnl-text">{item.account_name}</span>
                                                    </div>
                                                </td>
                                                <td className="right-align px-6 py-3.5 num-audit font-black text-rose-700 text-sm">
                                                    ({formatNumber(item.amount)})
                                                </td>
                                            </tr>
                                        ))}
                                        <tr className="bg-slate-50/50 font-black border-b-4 border-slate-200/50">
                                            <td className="px-6 py-4 text-[11px] uppercase tracking-widest font-black text-slate-500">Trading Gross Margin (Surplus)</td>
                                            <td className="right-align px-6 py-4 text-xl num-audit text-slate-900">
                                                <span className="text-xs mr-2 text-slate-300">PKR</span>
                                                {formatNumber(reportData?.grossProfit || 0)}
                                            </td>
                                        </tr>

                                        {/* INDIRECT EXPENSES SECTION */}
                                        <tr className="bg-slate-100/50">
                                            <td colSpan={2} className="px-6 py-3">
                                                <div className="flex items-center gap-2">
                                                    <div className="h-6 w-1 bg-slate-400 rounded-full"></div>
                                                    <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-600">Indirect & Administrative Expenses</span>
                                                </div>
                                            </td>
                                        </tr>
                                        {reportData?.expenses.map((item, i) => (
                                            <tr key={i} className="group hover:bg-slate-50 border-b border-slate-100 transition-colors">
                                                <td className="px-10 py-3.5 text-slate-600 font-medium">
                                                    <div className="flex items-center gap-3">
                                                        <div className="h-1.5 w-1.5 rounded-full bg-slate-200 group-hover:bg-slate-900 transition-all"></div>
                                                        <span className="font-bold uppercase pnl-text">{item.account_name}</span>
                                                    </div>
                                                </td>
                                                <td className="right-align px-6 py-3.5 num-audit font-bold text-rose-600">
                                                    ({formatNumber(item.amount)})
                                                </td>
                                            </tr>
                                        ))}
                                        {reportData?.expenses.length === 0 && (
                                            <tr><td colSpan={2} className="px-6 py-10 text-center italic text-slate-400 font-medium tracking-widest text-[10px] uppercase">No administrative expenses recorded in this period</td></tr>
                                        )}
                                    </tbody>
                                    <tfoot>
                                        <tr className={cn(
                                            "text-white shadow-2xl relative z-10",
                                            (reportData?.netProfit || 0) >= 0 ? "bg-slate-950" : "bg-rose-950"
                                        )}>
                                            <td className="px-6 py-10 border-r border-white/5">
                                                <div className="flex flex-col gap-1">
                                                    <span className="text-[10px] font-black uppercase tracking-[0.3em] opacity-40">Statement Summary</span>
                                                    <span className="text-xl font-black uppercase tracking-tight">
                                                        {(reportData?.netProfit || 0) >= 0 ? "Net Surplus (Profit)" : "Net Deficit (Loss)"}
                                                    </span>
                                                </div>
                                            </td>
                                            <td className="right-align px-8 py-10">
                                                <div className="flex flex-col items-end gap-1">
                                                    <span className="text-[10px] font-black uppercase tracking-[0.3em] opacity-40">Final Position</span>
                                                    <span className="text-5xl font-black num-audit text-white tracking-tighter drop-shadow-lg">
                                                        {formatPKR(reportData?.netProfit || 0)}
                                                    </span>
                                                    <div className="h-1.5 w-24 bg-white/20 rounded-full mt-2">
                                                        <div
                                                            className={cn("h-full rounded-full bg-white", (reportData?.netProfit || 0) >= 0 ? "opacity-60" : "opacity-30")}
                                                            style={{ width: `${Math.min(Math.abs((reportData?.netProfit || 0) / (reportData?.totalIncome || 1)) * 100, 100)}%` }}
                                                        ></div>
                                                    </div>
                                                </div>
                                            </td>
                                        </tr>
                                    </tfoot>
                                </table>
                            </div>

                        </>
                    )}
                </div>

            </div>
        </DashboardLayout>


    );
}
