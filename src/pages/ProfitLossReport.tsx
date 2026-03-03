import { useState, useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { supabase } from '@/integrations/supabase/client';
import { formatPKR, formatNumber } from '@/lib/format';
import { Button } from '@/components/ui/button';
import { Printer, Loader2, Landmark, TrendingUp, TrendingDown, PieChart } from 'lucide-react';
import { cn } from '@/lib/utils';

interface PnLRow {
    section_code: string;
    section_name: string;
    account_name: string;
    amount: number;
}

export default function ProfitLossReport() {
    const today = new Date();
    const firstDay = new Date(today.getFullYear(), today.getMonth(), 1).toISOString().split('T')[0];
    const currentDay = today.toISOString().split('T')[0];

    const [startDate, setStartDate] = useState<string>(firstDay);
    const [endDate, setEndDate] = useState<string>(currentDay);

    const { data: rawData, isLoading, error } = useQuery<PnLRow[]>({
        queryKey: ['pnl-v13-grouped', startDate, endDate],
        queryFn: async () => {
            const { data, error } = await (supabase.rpc as any)('get_profit_loss_v13', {
                p_start_date: startDate,
                p_end_date: endDate
            });

            if (error) throw error;
            return data as PnLRow[];
        }
    });

    const report = useMemo(() => {
        if (!rawData) return null;

        // Group by section_code
        const sections: Record<string, { name: string, items: PnLRow[], total: number }> = {};

        rawData.forEach(row => {
            if (!sections[row.section_code]) {
                sections[row.section_code] = { name: row.section_name, items: [], total: 0 };
            }
            sections[row.section_code].items.push(row);
            sections[row.section_code].total += Number(row.amount);
        });

        const totalRevenue = sections['10']?.total || 0;
        const totalCOGS = sections['20']?.total || 0;
        const grossProfit = totalRevenue - totalCOGS;

        const totalExpenses = Object.keys(sections)
            .filter(code => parseInt(code) >= 30)
            .reduce((sum, code) => sum + sections[code].total, 0);

        const netIncome = grossProfit - totalExpenses;

        return {
            sections,
            totalRevenue,
            totalCOGS,
            grossProfit,
            totalExpenses,
            netIncome
        };
    }, [rawData]);

    if (error) {
        return (
            <DashboardLayout>
                <div className="max-w-4xl mx-auto p-8">
                    <div className="bg-rose-50 p-8 rounded-3xl border border-rose-100 shadow-sm">
                        <h2 className="text-rose-900 font-black uppercase text-xs tracking-widest mb-2">Financial Engine Error</h2>
                        <p className="text-rose-700 font-bold text-sm">{(error as Error).message}</p>
                    </div>
                </div>
            </DashboardLayout>
        );
    }

    return (
        <DashboardLayout>
            <div className="max-w-5xl mx-auto pb-32 print:p-0 animate-in fade-in duration-700">
                {/* STICKY FILTER BAR */}
                <div className="sticky-filter-bar print:hidden px-6 backdrop-blur-xl bg-white/90 border-b border-slate-200/60 z-30 transition-all">
                    <div className="max-w-5xl mx-auto flex flex-col lg:flex-row items-start lg:items-center justify-between gap-6 py-6">
                        <div className="flex items-center gap-4">
                            <div className="bg-slate-900 p-3 rounded-2xl text-white shadow-xl shadow-slate-200">
                                <TrendingUp className="h-6 w-6" />
                            </div>
                            <div>
                                <h1 className="text-2xl font-black tracking-tighter text-slate-900 uppercase leading-none">P&L Statement</h1>
                                <p className="text-slate-400 font-bold uppercase tracking-[0.2em] text-[10px] mt-1">Unified Classical Format v13</p>
                            </div>
                        </div>

                        <div className="flex flex-wrap items-center gap-4 bg-slate-50 p-2.5 border border-slate-200/80 shadow-inner rounded-2xl">
                            <div className="flex items-center gap-4 px-3">
                                <div className="flex flex-col">
                                    <label className="text-[9px] font-black uppercase text-slate-400 mb-1 tracking-widest">Start Period</label>
                                    <input type="date" value={startDate} onChange={e => setStartDate(e.target.value)} className="h-10 px-4 border-none bg-white rounded-xl shadow-sm font-black text-[11px] text-slate-700 focus:ring-2 focus:ring-slate-900" />
                                </div>
                                <div className="flex flex-col">
                                    <label className="text-[9px] font-black uppercase text-slate-400 mb-1 tracking-widest">End Period</label>
                                    <input type="date" value={endDate} onChange={e => setEndDate(e.target.value)} className="h-10 px-4 border-none bg-white rounded-xl shadow-sm font-black text-[11px] text-slate-700 focus:ring-2 focus:ring-slate-900" />
                                </div>
                            </div>
                            <Button
                                className="h-11 px-8 rounded-xl bg-slate-900 hover:bg-black text-white font-black uppercase text-[10px] tracking-widest gap-2 shadow-xl shadow-slate-200 transition-all hover:scale-[1.02]"
                                onClick={() => window.print()}
                            >
                                <Printer className="h-4 w-4" /> Export Report
                            </Button>
                        </div>
                    </div>
                </div>

                <div className="px-6 mt-10 space-y-12">
                    {isLoading || !report ? (
                        <div className="flex flex-col items-center justify-center min-h-[50vh] gap-6 bg-slate-50/50 rounded-[2.5rem] border-2 border-dashed border-slate-100">
                            <Loader2 className="h-12 w-12 animate-spin text-slate-300" />
                            <div className="text-center">
                                <span className="text-[11px] font-black uppercase tracking-[0.4em] text-slate-400 block">Compiling Ledger Data</span>
                                <span className="text-[9px] font-bold text-slate-300 uppercase tracking-widest mt-1 italic block">Verifying transactional integrity...</span>
                            </div>
                        </div>
                    ) : (
                        <div className="space-y-10 print:space-y-6">
                            {/* PROFIT SUMMARY CARDS - HIDDEN ON PRINT */}
                            <div className="grid grid-cols-1 md:grid-cols-3 gap-6 print:hidden">
                                <div className="bg-white p-6 rounded-[2rem] border border-slate-100 shadow-sm hover:shadow-md transition-shadow group">
                                    <p className="text-[9px] font-black uppercase tracking-[0.2em] text-slate-400 mb-2 group-hover:text-emerald-500 transition-colors">Gross Profit</p>
                                    <h3 className="text-2xl font-black text-slate-900">{formatPKR(report.grossProfit)}</h3>
                                    <div className="mt-4 flex items-center justify-between">
                                        <span className="text-[8px] font-bold uppercase text-slate-300">Margin Analysis</span>
                                        <PieChart className="h-4 w-4 text-slate-200" />
                                    </div>
                                </div>
                                <div className="bg-white p-6 rounded-[2rem] border border-slate-100 shadow-sm hover:shadow-md transition-shadow group">
                                    <p className="text-[9px] font-black uppercase tracking-[0.2em] text-slate-400 mb-2 group-hover:text-rose-500 transition-colors">Operating Burn</p>
                                    <h3 className="text-2xl font-black text-slate-900">{formatPKR(report.totalExpenses)}</h3>
                                    <div className="mt-4 h-1 w-full bg-slate-50 rounded-full overflow-hidden">
                                        <div className="h-full bg-rose-400/30" style={{ width: '40%' }}></div>
                                    </div>
                                </div>
                                <div className={cn(
                                    "p-6 rounded-[2rem] border shadow-sm transition-all duration-500",
                                    report.netIncome >= 0 ? "bg-emerald-50 border-emerald-100/50 text-emerald-900" : "bg-rose-50 border-rose-100/50 text-rose-900"
                                )}>
                                    <p className="text-[9px] font-black uppercase tracking-[0.2em] opacity-60 mb-2">Net Bottom Line</p>
                                    <h3 className="text-2xl font-black tracking-tighter">{formatPKR(report.netIncome)}</h3>
                                    <p className="text-[9px] font-bold uppercase mt-4 tracking-wider flex items-center gap-1">
                                        {report.netIncome >= 0 ? <TrendingUp className="h-3 w-3" /> : <TrendingDown className="h-3 w-3" />}
                                        {report.netIncome >= 0 ? "Profitable Period" : "Loss Detected"}
                                    </p>
                                </div>
                            </div>

                            {/* MAIN REPORT TABLE */}
                            <div className="bg-white border-2 border-slate-50 rounded-[2.5rem] overflow-hidden shadow-2xl shadow-slate-200/50 print:border-none print:shadow-none">
                                <table className="w-full border-collapse">
                                    <thead>
                                        <tr className="bg-slate-900 text-white border-b border-white/10 print:bg-slate-100 print:text-black">
                                            <th className="text-left px-10 py-6 text-[11px] font-black uppercase tracking-[0.3em]">Account Description</th>
                                            <th className="text-right px-10 py-6 text-[11px] font-black uppercase tracking-[0.3em]">Period Balance (PKR)</th>
                                        </tr>
                                    </thead>
                                    <tbody className="text-sm">
                                        {Object.keys(report.sections).sort().map((code, index) => {
                                            const section = report.sections[code];
                                            const isCOGS = code === '20';
                                            const isRevenue = code === '10';

                                            return (
                                                <div key={code} className="contents">
                                                    {/* SECTION HEADER */}
                                                    <tr className="bg-slate-50/80 border-y border-slate-100">
                                                        <td colSpan={2} className="px-10 py-4 font-black text-slate-900 uppercase text-[11px] tracking-[0.2em]">
                                                            {section.name}
                                                        </td>
                                                    </tr>

                                                    {/* LINE ITEMS */}
                                                    {section.items.map((item, i) => (
                                                        <tr key={`${code}-${i}`} className="group hover:bg-slate-50/50 transition-colors">
                                                            <td className="px-14 py-3.5 font-bold uppercase text-slate-500 text-[11px] tracking-tight group-hover:text-slate-900 transition-colors border-b border-slate-50/50">
                                                                {item.account_name}
                                                            </td>
                                                            <td className={cn(
                                                                "text-right px-10 py-3.5 font-black tabular-nums border-b border-slate-50/50",
                                                                isRevenue ? "text-slate-900" : "text-rose-600/80"
                                                            )}>
                                                                {isRevenue ? formatNumber(item.amount) : `(${formatNumber(item.amount)})`}
                                                            </td>
                                                        </tr>
                                                    ))}

                                                    {/* SECTION TOTAL */}
                                                    <tr className="bg-white border-b-2 border-slate-100">
                                                        <td className="px-10 py-4 uppercase text-slate-400 font-bold text-[10px] tracking-widest italic">
                                                            Total {section.name}
                                                        </td>
                                                        <td className={cn(
                                                            "text-right px-10 py-4 font-black text-sm tabular-nums",
                                                            isRevenue ? "text-slate-900 font-black underline decoration-slate-200 underline-offset-8" : "text-rose-700"
                                                        )}>
                                                            {isRevenue ? formatNumber(section.total) : `(${formatNumber(section.total)})`}
                                                        </td>
                                                    </tr>

                                                    {/* INJECT GROSS PROFIT AFTER COGS */}
                                                    {isCOGS && (
                                                        <tr className="bg-emerald-50/40 font-black border-y-4 border-white">
                                                            <td className="px-10 py-6 uppercase text-emerald-900 text-[11px] tracking-[0.3em] flex items-center gap-2">
                                                                <div className="w-2 h-4 bg-emerald-500 rounded-full" />
                                                                Gross Profit (Margin)
                                                            </td>
                                                            <td className="text-right px-10 py-6 text-xl tabular-nums text-emerald-900 tracking-tighter">
                                                                {formatPKR(report.grossProfit)}
                                                            </td>
                                                        </tr>
                                                    )}
                                                </div>
                                            );
                                        })}
                                    </tbody>
                                    <tfoot>
                                        <tr className={cn(
                                            "font-black text-2xl print:text-lg transition-all duration-700",
                                            report.netIncome >= 0 ? "bg-slate-900 text-white" : "bg-rose-900 text-white"
                                        )}>
                                            <td className="px-10 py-10 uppercase tracking-[0.4em] border-r border-white/5">
                                                Net Result (P&L)
                                            </td>
                                            <td className="text-right px-10 py-10 tabular-nums tracking-tighter">
                                                {formatPKR(report.netIncome)}
                                            </td>
                                        </tr>
                                    </tfoot>
                                </table>
                            </div>

                            {/* AUDIT SIGNATURE - PRINT ONLY */}
                            <div className="hidden print:flex justify-between mt-20 px-10">
                                <div className="border-t-2 border-slate-900 pt-3 w-48 text-center">
                                    <p className="text-[10px] font-black uppercase tracking-widest text-slate-400">Accountant Sign</p>
                                </div>
                                <div className="border-t-2 border-slate-900 pt-3 w-48 text-center">
                                    <p className="text-[10px] font-black uppercase tracking-widest text-slate-400">Chief Executive</p>
                                </div>
                            </div>
                        </div>
                    )}
                </div>
            </div>
        </DashboardLayout>
    );
}
