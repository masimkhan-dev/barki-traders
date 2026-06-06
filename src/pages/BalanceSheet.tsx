import { Fragment, useState, useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { supabase } from '@/integrations/supabase/client';
import { formatPKR, formatNumber } from '@/lib/format';
import { Button } from '@/components/ui/button';
import { Printer, Loader2, Scale, AlertCircle, Wallet, ShieldCheck, Landmark } from 'lucide-react';
import { cn } from '@/lib/utils';

interface BSLineItem {
    section_code: string;
    section_name: string;
    group_name: string;
    account_name: string;
    balance: number;
}

export default function BalanceSheet() {
    const [asOfDate, setAsOfDate] = useState<string>(new Date().toISOString().split('T')[0]);

    const { data: rawData, isLoading, error } = useQuery<BSLineItem[]>({
        queryKey: ['balance-sheet-v13', asOfDate],
        queryFn: async () => {
            const { data, error } = await (supabase.rpc as any)('get_financial_position_v13', { p_date: asOfDate });
            if (error) throw error;
            return data as BSLineItem[];
        }
    });

    const report = useMemo(() => {
        if (!rawData) return null;

        const sections: Record<string, {
            name: string,
            groups: Record<string, { items: BSLineItem[], total: number }>,
            total: number
        }> = {};

        rawData.forEach(row => {
            if (!sections[row.section_code]) {
                sections[row.section_code] = { name: row.section_name, groups: {}, total: 0 };
            }
            if (!sections[row.section_code].groups[row.group_name]) {
                sections[row.section_code].groups[row.group_name] = { items: [], total: 0 };
            }

            sections[row.section_code].groups[row.group_name].items.push(row);
            sections[row.section_code].groups[row.group_name].total += Number(row.balance);
            sections[row.section_code].total += Number(row.balance);
        });

        const totalAssets = (sections['10']?.total || 0) + (sections['15']?.total || 0);
        const totalLiabilities = sections['20']?.total || 0;
        const totalEquity = sections['30']?.total || 0;
        const totalLiabilityAndEquity = totalLiabilities + totalEquity;

        return {
            sections,
            totalAssets,
            totalLiabilities,
            totalEquity,
            totalLiabilityAndEquity,
            isBalanced: Math.abs(totalAssets - totalLiabilityAndEquity) < 1
        };
    }, [rawData]);

    if (error) {
        return (
            <DashboardLayout>
                <div className="max-w-4xl mx-auto p-8">
                    <div className="bg-rose-50 p-8 rounded-none border-2 border-rose-200 shadow-none">
                        <h2 className="text-rose-900 font-black uppercase text-xs tracking-widest mb-2">Accounting Engine Fault</h2>
                        <p className="text-rose-700 font-bold text-sm">{(error as Error).message}</p>
                    </div>
                </div>
            </DashboardLayout>
        );
    }

    return (
        <DashboardLayout>
            <div className="max-w-5xl mx-auto pb-32 print:p-0">
                {/* STICKY HEADER */}
                <div className="sticky-filter-bar print:hidden px-6 bg-white border-b border-slate-300 z-30 transition-none">
                    <div className="max-w-5xl mx-auto flex flex-col lg:flex-row items-start lg:items-center justify-between gap-6 py-6">
                        <div className="flex items-center gap-4">
                            <div className="bg-slate-900 p-3 rounded-none text-white shadow-none">
                                <Scale className="h-6 w-6" />
                            </div>
                            <div>
                                <h1 className="text-2xl font-black tracking-tighter text-slate-900 uppercase leading-none">Balance Sheet</h1>
                                <p className="text-slate-400 font-bold uppercase tracking-[0.2em] text-[10px] mt-1">Financial Position Statement v13</p>
                            </div>
                        </div>

                        <div className="flex w-full lg:w-auto flex-col sm:flex-row sm:items-end gap-3 bg-slate-50 p-3 border border-slate-200 shadow-none rounded-none">
                            <div className="flex flex-col sm:px-4">
                                <label className="text-[11px] font-black uppercase text-slate-500 mb-1 tracking-normal sm:text-center">As Of Date</label>
                                <input type="date" value={asOfDate} onChange={e => setAsOfDate(e.target.value)} className="h-10 px-4 border border-slate-300 bg-white rounded-none shadow-none font-black text-[11px] text-slate-700 focus:ring-2 focus:ring-slate-900" />
                            </div>
                            <Button
                                className="h-11 w-full sm:w-auto px-8 lg:px-10 rounded-none bg-slate-900 hover:bg-black text-white font-black uppercase text-[11px] tracking-widest gap-2 shadow-none transition-none active:scale-100"
                                onClick={() => window.print()}
                                aria-label="Print balance sheet"
                            >
                                <Printer className="h-4 w-4" /> Print Statement
                            </Button>
                        </div>
                    </div>
                </div>

                <div className="px-6 mt-10 space-y-12">
                    {isLoading || !report ? (
                        <div className="flex flex-col items-center justify-center min-h-[50vh] gap-6 bg-slate-50/50 rounded-none border-2 border-dashed border-slate-200">
                            <Loader2 className="h-12 w-12 animate-spin text-slate-200" />
                            <div className="text-center">
                                <span className="text-[11px] font-black uppercase tracking-[0.4em] text-slate-400 block">Reconciling Ledger State</span>
                            </div>
                        </div>
                    ) : (
                        <div className="space-y-12">
                            {/* BALANCE CHECK AND SUMMARY CARDS */}
                            {!report.isBalanced && (
                                <div className="bg-rose-50 border-2 border-rose-200 p-6 rounded-none flex items-center gap-6 print:hidden">
                                    <div className="bg-rose-600 p-3 rounded-none text-white shadow-none">
                                        <AlertCircle className="h-6 w-6" />
                                    </div>
                                    <div>
                                        <h3 className="text-rose-900 font-black uppercase text-xs tracking-widest">Reconciliation Warning</h3>
                                        <p className="text-rose-700 text-sm font-bold">Assets do not match Equity + Liabilities. Difference: {formatPKR(Math.abs(report.totalAssets - report.totalLiabilityAndEquity))}</p>
                                    </div>
                                </div>
                            )}

                            <div className="grid grid-cols-1 md:grid-cols-3 gap-6 print:hidden">
                                <section className="summary-card">
                                    <div className="flex items-center gap-3 mb-4">
                                        <div className="bg-emerald-50 p-2 rounded-none text-emerald-600 border border-emerald-100"><Wallet className="h-4 w-4" /></div>
                                        <p className="text-[11px] font-black uppercase tracking-[0.2em] text-slate-500">Total Solvency</p>
                                    </div>
                                    <h3 className="text-2xl font-black text-slate-900 tracking-tighter">{formatPKR(report.totalAssets)}</h3>
                                    <p className="text-[11px] font-bold text-slate-400 uppercase mt-2">Combined Asset Value</p>
                                </section>
                                <section className="summary-card">
                                    <div className="flex items-center gap-3 mb-4">
                                        <div className="bg-slate-50 p-2 rounded-none text-slate-600 border border-slate-200"><Landmark className="h-4 w-4" /></div>
                                        <p className="text-[11px] font-black uppercase tracking-[0.2em] text-slate-500">Risk Exposure</p>
                                    </div>
                                    <h3 className="text-2xl font-black text-slate-900 tracking-tighter">{formatPKR(report.totalLiabilities)}</h3>
                                    <p className="text-[11px] font-bold text-slate-400 uppercase mt-2">Total Outstanding Debt</p>
                                </section>
                                <section className="bg-slate-900 p-6 rounded-none shadow-none overflow-hidden relative border border-slate-900">
                                    <div className="absolute -right-4 -top-4 opacity-10">
                                        <ShieldCheck className="h-24 w-24 text-white" />
                                    </div>
                                    <div className="flex items-center gap-3 mb-4">
                                        <p className="text-[11px] font-black uppercase tracking-[0.2em] text-slate-400">Net Worth (Equity)</p>
                                    </div>
                                    <h3 className="text-2xl font-black text-white tracking-tighter">{formatPKR(report.totalEquity)}</h3>
                                    <p className="text-[11px] font-bold text-emerald-400 uppercase mt-2 tracking-widest">Owner's Net Position</p>
                                </section>
                            </div>

                            {/* MAIN TABLE DESIGN */}
                            <div className="audit-table-shell rounded-none shadow-none print:border-none print:shadow-none">
                                <table className="w-full min-w-[720px] border-collapse">
                                    <thead>
                                        <tr className="bg-slate-900 text-white print:bg-slate-100 print:text-black">
                                            <th className="text-left px-10 py-6 text-[11px] font-black uppercase tracking-[0.3em]">Accounting Head</th>
                                            <th className="text-right px-10 py-6 text-[11px] font-black uppercase tracking-[0.3em]">Fair Value (PKR)</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {/* ASSETS MASTER SECTION */}
                                        <tr className="bg-emerald-50/50"><td colSpan={2} className="px-10 py-4 font-black text-emerald-900 uppercase text-xs tracking-[0.4em] border-b border-emerald-100/50">I. ASSETS & INVESTMENTS</td></tr>

                                        {Object.keys(report.sections).filter(c => c === '10' || c === '15').sort().map(code => {
                                            const section = report.sections[code];
                                            return Object.entries(section.groups).map(([groupName, group]) => (
                                                <Fragment key={`${code}-${groupName}`}>
                                                    <tr className="bg-slate-50/40"><td colSpan={2} className="px-12 py-3 font-black text-slate-400 uppercase text-[10px] tracking-[0.2em]">{groupName}</td></tr>
                                                    {group.items.map((item, i) => (
                                                        <tr key={`${item.account_name}-${i}`} className="hover:bg-slate-50/50 transition-none">
                                                            <td className="px-16 py-3 font-bold uppercase text-slate-700 text-[11px] border-b border-slate-50/50">{item.account_name}</td>
                                                            <td className="text-right px-10 py-3 font-black tabular-nums text-slate-900 border-b border-slate-50/50">{formatNumber(item.balance)}</td>
                                                        </tr>
                                                    ))}
                                                    <tr className="bg-white border-b border-slate-100">
                                                        <td className="px-12 py-3 uppercase text-slate-400 font-bold text-[9px] tracking-widest italic">Total {groupName}</td>
                                                        <td className="text-right px-10 py-3 font-black text-sm tabular-nums text-slate-900">{formatNumber(group.total)}</td>
                                                    </tr>
                                                </Fragment>
                                            ));
                                        })}

                                        <tr className="bg-emerald-900 text-white font-black">
                                            <td className="px-10 py-6 uppercase tracking-[0.4em] text-xs">TOTAL ASSETS</td>
                                            <td className="text-right px-10 py-6 text-xl tabular-nums tracking-tighter">{formatPKR(report.totalAssets)}</td>
                                        </tr>

                                        {/* LIABILITIES & EQUITY SECTION */}
                                        <tr className="bg-slate-50/50 pt-10"><td colSpan={2} className="px-10 py-4 font-black text-slate-900 uppercase text-xs tracking-[0.4em] border-b border-slate-200">II. LIABILITIES & EQUITY</td></tr>

                                        {Object.keys(report.sections).filter(c => c === '20' || c === '30').sort().map(code => {
                                            const section = report.sections[code];
                                            return Object.entries(section.groups).map(([groupName, group]) => (
                                                <Fragment key={`${code}-${groupName}`}>
                                                    <tr className="bg-slate-50/40"><td colSpan={2} className="px-12 py-3 font-black text-slate-400 uppercase text-[10px] tracking-[0.2em]">{groupName}</td></tr>
                                                    {group.items.map((item, i) => (
                                                        <tr key={`${item.account_name}-${i}`} className="hover:bg-slate-50/50 transition-none">
                                                            <td className="px-16 py-3 font-bold uppercase text-slate-700 text-[11px] border-b border-slate-50/50">{item.account_name}</td>
                                                            <td className="text-right px-10 py-3 font-black tabular-nums text-slate-900 border-b border-slate-50/50">{formatNumber(item.balance)}</td>
                                                        </tr>
                                                    ))}
                                                    <tr className="bg-white border-b border-slate-100">
                                                        <td className="px-12 py-3 uppercase text-slate-400 font-bold text-[9px] tracking-widest italic">Total {groupName}</td>
                                                        <td className="text-right px-10 py-3 font-black text-sm tabular-nums text-slate-900">{formatNumber(group.total)}</td>
                                                    </tr>
                                                </Fragment>
                                            ));
                                        })}

                                        <tr className="bg-slate-900 text-white font-black">
                                            <td className="px-10 py-6 uppercase tracking-[0.4em] text-xs">TOTAL LIABILITIES & EQUITY</td>
                                            <td className="text-right px-10 py-6 text-xl tabular-nums tracking-tighter">{formatPKR(report.totalLiabilityAndEquity)}</td>
                                        </tr>
                                    </tbody>
                                </table>
                            </div>

                            {/* AUDIT SIGNATURE - PRINT ONLY */}
                            <div className="hidden print:flex justify-between mt-24 px-10">
                                <div className="border-t border-slate-300 pt-4 w-52 text-center">
                                    <p className="text-[10px] font-black uppercase tracking-widest text-slate-500">Chief Accountant</p>
                                </div>
                                <div className="border-t border-slate-300 pt-4 w-52 text-center">
                                    <p className="text-[10px] font-black uppercase tracking-widest text-slate-500">Managing Director</p>
                                </div>
                            </div>

                            <div className="text-center print:hidden opacity-30 italic text-[10px] font-bold uppercase tracking-widest mt-8">
                                Document digitally generated on {new Date().toLocaleDateString()}
                            </div>
                        </div>
                    )}
                </div>
            </div>
        </DashboardLayout>
    );
}
