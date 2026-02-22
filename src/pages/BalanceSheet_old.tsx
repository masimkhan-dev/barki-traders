import { useState, useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { supabase } from '@/integrations/supabase/client';
import { formatPKR } from '@/lib/format';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import { Printer, Scale, AlertCircle, Loader2 } from 'lucide-react';
import { cn } from '@/lib/utils';

export default function BalanceSheet() {
    const [asOfDate, setAsOfDate] = useState<string>(new Date().toISOString().split('T')[0]);

    const { data: sheetData, isLoading } = useQuery<any[], Error>({
        queryKey: ['balance-sheet', asOfDate],
        queryFn: async () => {
            const { data, error } = await (supabase.rpc as any)('get_financial_position', { p_date: asOfDate });
            if (error) throw error;
            return data as any[];
        },
        staleTime: 1000 * 60 * 5,
        gcTime: 1000 * 60 * 30
    });

    // FILTER BY CATEGORY
    const rawAssets = useMemo(() => sheetData?.filter(d => String(d.category).toUpperCase() === 'ASSETS') || [], [sheetData]);
    const rawLiabilities = useMemo(() => sheetData?.filter(d => String(d.category).toUpperCase() === 'LIABILITIES') || [], [sheetData]);
    const equity = useMemo(() => sheetData?.filter(d => String(d.category).toUpperCase() === 'EQUITY') || [], [sheetData]);

    // ASSETS SUMMARY (Receivables)
    const assets = useMemo(() => {
        return rawAssets.reduce((acc: any[], curr: any) => {
            const isReceivable = curr.sub_category?.toLowerCase().includes('receivable') ||
                curr.account_name?.toLowerCase().includes('accounts receivable');

            if (isReceivable) {
                let summary = acc.find(i => i.isReceivableSummary);
                if (!summary) {
                    summary = { account_name: 'Total Market Receivables (Lena)', balance: 0, sub_category: 'Current Assets', isReceivableSummary: true };
                    acc.push(summary);
                }
                summary.balance += Number(curr.balance) || 0;
            } else {
                acc.push(curr);
            }
            return acc;
        }, []);
    }, [rawAssets]);

    // LIABILITIES SUMMARY (Payables)
    const liabilities = useMemo(() => {
        return rawLiabilities.reduce((acc: any[], curr: any) => {
            const isPayable = curr.sub_category?.toLowerCase().includes('payable') ||
                curr.account_name?.toLowerCase().includes('accounts payable');

            if (isPayable) {
                let summary = acc.find(i => i.isPayableSummary);
                if (!summary) {
                    summary = { account_name: 'Total Supplier Payables (Dena)', balance: 0, sub_category: 'Current Liabilities', isPayableSummary: true };
                    acc.push(summary);
                }
                summary.balance += Number(curr.balance) || 0;
            } else {
                acc.push(curr);
            }
            return acc;
        }, []);
    }, [rawLiabilities]);

    // TOTALS
    const totalAssets = useMemo(() => rawAssets.reduce((sum, d) => sum + (Number(d.balance) || 0), 0), [rawAssets]);
    const totalLiabilities = useMemo(() => rawLiabilities.reduce((sum, d) => sum + (Number(d.balance) || 0), 0), [rawLiabilities]);
    const totalEquity = useMemo(() => equity.reduce((sum, d) => sum + (Number(d.balance) || 0), 0), [equity]);

    const isBalanced = Math.abs(totalAssets - (totalLiabilities + totalEquity)) < 1;

    if (isLoading) return (
        <div className="flex flex-col items-center justify-center min-h-[60vh] gap-4">
            <Loader2 className="h-10 w-10 animate-spin text-slate-300" />
            <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-400">Auditing Financial Position...</span>
        </div>
    );

    return (
        <DashboardLayout>
            <div className="max-w-7xl mx-auto space-y-8 px-4 py-8 print:p-0">
                <BalanceSheetHeader asOfDate={asOfDate} setAsOfDate={setAsOfDate} />
                <SummaryCards totalAssets={totalAssets} totalLiabilities={totalLiabilities} isBalanced={isBalanced} />
                <MainTables assets={assets} liabilities={liabilities} equity={equity} totalAssets={totalAssets} totalLiabilities={totalLiabilities} totalEquity={totalEquity} />
            </div>
        </DashboardLayout>
    );
}

/* ========================= COMPONENTS ========================= */

function BalanceSheetHeader({ asOfDate, setAsOfDate }: { asOfDate: string, setAsOfDate: (val: string) => void }) {
    return (
        <div className="flex flex-col md:flex-row justify-between items-start md:items-end border-b-4 border-slate-900 pb-6 gap-4">
            <div className="report-header mb-0">
                <div className="flex items-center gap-2 mb-2">
                    <Scale className="h-6 w-6 text-blue-600" />
                    <span className="bg-slate-900 text-white text-[10px] px-2 py-0.5 font-black uppercase tracking-widest">Live Audit Mode</span>
                </div>
                <h1 className="text-3xl font-black text-slate-900 uppercase tracking-tighter">Naveed Musazai</h1>
                <p className="text-slate-500 font-bold text-sm tracking-wide">Statement of Financial Position (Balance Sheet)</p>
            </div>
            <div className="flex flex-wrap items-center gap-4 print:hidden">
                <div className="flex flex-col bg-slate-50 p-2 border border-slate-200 rounded-sm">
                    <label className="text-[9px] font-black uppercase text-slate-500 mb-1 px-1">Effective Date</label>
                    <input type="date" value={asOfDate} onChange={e => setAsOfDate(e.target.value)} className="h-9 px-3 border-none bg-transparent font-black text-xs outline-none focus:ring-0" />
                </div>
                <Button variant="outline" className="h-13 rounded-none border-2 border-slate-900 font-black uppercase text-xs hover:bg-slate-900 hover:text-white transition-all" onClick={() => window.print()}>
                    <Printer className="h-4 w-4 mr-2" /> Print Report
                </Button>
            </div>
        </div>
    );
}

function SummaryCards({ totalAssets, totalLiabilities, isBalanced }: { totalAssets: number, totalLiabilities: number, isBalanced: boolean }) {
    return (
        <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
            <Card className="p-4 border-l-4 border-l-emerald-500 rounded-none bg-emerald-50/10 shadow-sm">
                <span className="text-[10px] font-black text-slate-500 uppercase">Total Assets</span>
                <div className="text-xl font-black text-emerald-700">{formatPKR(totalAssets)}</div>
            </Card>
            <Card className="p-4 border-l-4 border-l-rose-500 rounded-none bg-rose-50/10 shadow-sm">
                <span className="text-[10px] font-black text-slate-500 uppercase">Total Liabilities</span>
                <div className="text-xl font-black text-rose-700">{formatPKR(totalLiabilities)}</div>
            </Card>
            <Card className="p-4 border-l-4 border-l-blue-500 rounded-none bg-blue-50/10 shadow-sm">
                <span className="text-[10px] font-black text-slate-500 uppercase">Working Capital</span>
                <div className="text-xl font-black text-blue-700">{formatPKR(totalAssets - totalLiabilities)}</div>
            </Card>
            <Card className={cn(
                "p-4 border-l-4 rounded-none shadow-sm flex flex-col justify-center",
                isBalanced ? "border-l-emerald-600 bg-emerald-600 text-white" : "border-l-rose-600 bg-rose-600 text-white"
            )}>
                <div className="flex items-center gap-2">
                    {isBalanced ? <div className="h-2 w-2 rounded-full bg-white animate-pulse" /> : <AlertCircle className="h-4 w-4" />}
                    <span className="text-[10px] font-black uppercase">{isBalanced ? "Match: Clean" : "Match: Mismatch"}</span>
                </div>
                <div className="text-sm font-black uppercase">{isBalanced ? "Balance Matched" : `Diff: ${formatPKR(Math.abs(totalAssets - totalLiabilities))}`}</div>
            </Card>
        </div>
    );
}

function MainTables({ assets, liabilities, equity, totalAssets, totalLiabilities, totalEquity }: any) {
    return (
        <div className="grid grid-cols-1 lg:grid-cols-2 gap-12 bg-white p-2 rounded-sm">
            {/* ASSETS TABLE */}
            <AssetsTable assets={assets} totalAssets={totalAssets} />
            {/* LIABILITIES & EQUITY TABLE */}
            <LiabilitiesTable liabilities={liabilities} equity={equity} totalLiabilities={totalLiabilities} totalEquity={totalEquity} />
        </div>
    );
}

function AssetsTable({ assets, totalAssets }: any) {
    return (
        <div className="space-y-6">
            <div className="flex items-center gap-3">
                <div className="h-8 w-1.5 bg-emerald-600" />
                <h3 className="text-lg font-black uppercase tracking-tight text-slate-900 italic">Financial Assets</h3>
                <div className="flex-1 border-b border-dashed border-slate-300" />
            </div>
            <div className="overflow-hidden border border-slate-200">
                <table className="w-full text-left border-collapse">
                    <thead>
                        <tr className="bg-slate-900 text-white">
                            <th className="px-4 py-3 text-[10px] font-black uppercase tracking-widest">Classification & Description</th>
                            <th className="px-4 py-3 text-[10px] font-black uppercase tracking-widest text-right">Value (PKR)</th>
                        </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-100">
                        {assets.map((a: any, idx: number) => (
                            <tr key={idx} className="hover:bg-slate-50/80 transition-colors group">
                                <td className="px-4 py-3">
                                    <div className="flex flex-col">
                                        <span className="text-[8px] font-black text-blue-500 uppercase mb-0.5 tracking-tighter group-hover:tracking-widest transition-all italic">{a.sub_category}</span>
                                        <span className="font-black text-slate-800 uppercase text-xs">{a.account_name}</span>
                                    </div>
                                </td>
                                <td className="px-4 py-3 text-right font-black text-emerald-700 text-sm tabular-nums">{formatPKR(a.balance)}</td>
                            </tr>
                        ))}
                        {assets.length === 0 && (
                            <tr><td colSpan={2} className="py-20 text-center italic text-slate-300 uppercase font-black text-[10px] tracking-widest">No Active Assets Recorded</td></tr>
                        )}
                    </tbody>
                    <tfoot className="bg-slate-100 border-t-2 border-slate-900">
                        <tr>
                            <td className="px-4 py-4 font-black uppercase text-xs text-slate-900 italic">Sub-Total Assets</td>
                            <td className="px-4 py-4 text-right font-black text-xl text-slate-900 tabular-nums">{formatPKR(totalAssets)}</td>
                        </tr>
                    </tfoot>
                </table>
            </div>
        </div>
    );
}

function LiabilitiesTable({ liabilities, equity, totalLiabilities, totalEquity }: any) {
    return (
        <div className="space-y-6">
            <div className="flex items-center gap-3">
                <div className="h-8 w-1.5 bg-rose-600" />
                <h3 className="text-lg font-black uppercase tracking-tight text-slate-900 italic">Sources of Capital</h3>
                <div className="flex-1 border-b border-dashed border-slate-300" />
            </div>
            <div className="overflow-hidden border border-slate-200">
                <table className="w-full text-left border-collapse">
                    <thead>
                        <tr className="bg-slate-900 text-white">
                            <th className="px-4 py-3 text-[10px] font-black uppercase tracking-widest">Obligations & Equities</th>
                            <th className="px-4 py-3 text-[10px] font-black uppercase tracking-widest text-right">Value (PKR)</th>
                        </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-100">
                        <tr className="bg-slate-50"><td colSpan={2} className="px-4 py-2 text-[10px] font-black uppercase tracking-widest text-rose-600">Short-Term & Long-Term Liabilities</td></tr>
                        {liabilities.map((l: any, idx: number) => (
                            <tr key={idx} className="hover:bg-slate-50/80 transition-colors group">
                                <td className="px-4 py-3 font-black text-slate-800 uppercase text-xs italic">{l.account_name}</td>
                                <td className="px-4 py-3 text-right font-black text-rose-700 text-sm tabular-nums">{formatPKR(l.balance)}</td>
                            </tr>
                        ))}
                        <tr className="bg-slate-50 border-t"><td colSpan={2} className="px-4 py-2 text-[10px] font-black uppercase tracking-widest text-blue-600">Company Equity & Retained Earnings</td></tr>
                        {equity.map((e: any, idx: number) => (
                            <tr key={idx} className="hover:bg-slate-50/80 transition-colors group">
                                <td className="px-4 py-3 font-black text-slate-800 uppercase text-xs italic">{e.account_name}</td>
                                <td className="px-4 py-3 text-right font-black text-emerald-700 text-sm tabular-nums">{formatPKR(e.balance)}</td>
                            </tr>
                        ))}
                    </tbody>
                    <tfoot className="bg-slate-100 border-t-2 border-slate-900">
                        <tr>
                            <td className="px-4 py-4 font-black uppercase text-xs text-slate-900 italic">Total Liabilities & Equity</td>
                            <td className="px-4 py-4 text-right font-black text-xl text-slate-900 tabular-nums">{formatPKR(totalLiabilities + totalEquity)}</td>
                        </tr>
                    </tfoot>
                </table>
            </div>
        </div>
    );
}

