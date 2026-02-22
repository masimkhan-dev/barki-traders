import { useState, useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { supabase } from '@/integrations/supabase/client';
import { formatPKR, formatNumber } from '@/lib/format';
import { Button } from '@/components/ui/button';
import { Printer, Loader2, Scale, AlertCircle } from 'lucide-react';
import { Card } from '@/components/ui/card';
import { cn } from '@/lib/utils';

interface FinancialPosition {
    category: string;
    sub_category: string;
    account_name: string;
    balance: number;
}

export default function BalanceSheet() {
    const [asOfDate, setAsOfDate] = useState<string>(new Date().toISOString().split('T')[0]);

    const { data: rawData, isLoading, error } = useQuery<FinancialPosition[], Error>({
        queryKey: ['balance-sheet-v2', asOfDate],
        queryFn: async () => {
            const { data, error } = await (supabase.rpc as any)('get_financial_position', { p_date: asOfDate });
            if (error) throw error;
            return data as FinancialPosition[];
        }
    });

    const report = useMemo(() => {
        if (!rawData) return null;

        const classify = (item: FinancialPosition) => {
            const cat = item.category?.toUpperCase() || '';
            const sub = item.sub_category?.toUpperCase() || '';
            const name = item.account_name?.toUpperCase() || '';

            if (cat === 'ASSETS') {
                if (sub.includes('FIXED') || sub.includes('NON CURRENT') || name.includes('EQUIPMENT') || name.includes('VEHICLE')) {
                    return 'NON_CURRENT_ASSET';
                }
                if (name.includes('CASH')) return 'CASH';
                if (name.includes('BANK')) return 'BANK';
                if (name.includes('INVENTORY') || name.includes('STOCK')) return 'INVENTORY';
                return 'CURRENT_ASSET';
            }
            if (cat === 'LIABILITIES') {
                if (sub.includes('LONG TERM') || name.includes('LOAN') && !name.includes('PAYABLE')) {
                    return 'LONG_TERM_LIABILITY';
                }
                return 'CURRENT_LIABILITY';
            }
            if (cat === 'EQUITY') {
                return 'EQUITY';
            }
            return 'UNKNOWN';
        };

        const currentAssets: FinancialPosition[] = [];
        const cashAccounts: FinancialPosition[] = [];
        const bankAccounts: FinancialPosition[] = [];
        const inventoryAccounts: FinancialPosition[] = [];
        const nonCurrentAssets: FinancialPosition[] = [];

        const currentLiabilities: FinancialPosition[] = [];
        const longTermLiabilities: FinancialPosition[] = [];
        const equityAccounts: FinancialPosition[] = [];

        for (const item of rawData) {
            const type = classify(item);
            if (type === 'CASH') cashAccounts.push(item);
            else if (type === 'BANK') bankAccounts.push(item);
            else if (type === 'INVENTORY') inventoryAccounts.push(item);
            else if (type === 'CURRENT_ASSET') currentAssets.push(item);
            else if (type === 'NON_CURRENT_ASSET') nonCurrentAssets.push(item);
            else if (type === 'CURRENT_LIABILITY') currentLiabilities.push(item);
            else if (type === 'LONG_TERM_LIABILITY') longTermLiabilities.push(item);
            else if (type === 'EQUITY') equityAccounts.push(item);
        }

        const sum = (arr: FinancialPosition[]) => arr.reduce((acc, curr) => acc + (Number(curr.balance) || 0), 0);

        const totalCash = sum(cashAccounts);
        const totalBank = sum(bankAccounts);
        const totalInventory = sum(inventoryAccounts);
        const totalOtherCurrentAssets = sum(currentAssets);
        const totalCurrentAssets = totalCash + totalBank + totalInventory + totalOtherCurrentAssets;

        const totalNonCurrentAssets = sum(nonCurrentAssets);
        const totalAssets = totalCurrentAssets + totalNonCurrentAssets;

        const totalCurrentLiability = sum(currentLiabilities);
        const totalLongTermLiability = sum(longTermLiabilities);
        const totalLiabilities = totalCurrentLiability + totalLongTermLiability;

        const totalEquity = sum(equityAccounts);
        const totalLiabilityAndEquity = totalLiabilities + totalEquity;

        return {
            cashAccounts, bankAccounts, inventoryAccounts, currentAssets, nonCurrentAssets,
            currentLiabilities, longTermLiabilities, equityAccounts,
            totalCash, totalBank, totalInventory, totalOtherCurrentAssets, totalCurrentAssets, totalNonCurrentAssets, totalAssets,
            totalCurrentLiability, totalLongTermLiability, totalLiabilities, totalEquity, totalLiabilityAndEquity,
            isBalanced: Math.abs(totalAssets - totalLiabilityAndEquity) < 1
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
                                    <Scale className="h-6 w-6" />
                                </div>
                                <div>
                                    <h1 className="report-title text-2xl font-black tracking-tight text-slate-900 uppercase">Balance Sheet</h1>
                                    <p className="report-subtitle text-slate-500 font-bold uppercase tracking-[0.2em] text-[10px]">Corporate Accounting Format</p>
                                </div>
                            </div>
                        </div>

                        <div className="flex flex-wrap items-center gap-4 bg-white p-2 border border-slate-200 shadow-sm rounded-xl">
                            <div className="flex items-center gap-4 px-2">
                                <div className="flex flex-col">
                                    <label className="text-[9px] font-black uppercase text-slate-400 mb-1">As Of Date</label>
                                    <input type="date" value={asOfDate} onChange={e => setAsOfDate(e.target.value)} className="h-9 px-3 border border-slate-200 rounded-lg font-bold text-xs" />
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
                            <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-400">Compiling Balance Sheet...</span>
                        </div>
                    ) : (
                        <>
                            {!report.isBalanced && (
                                <Card className="p-4 border-l-4 border-l-rose-600 bg-rose-50 rounded-none shadow-sm flex items-center gap-3 print:hidden">
                                    <AlertCircle className="h-5 w-5 text-rose-600" />
                                    <div>
                                        <p className="text-sm font-black text-rose-900 uppercase">Balance Mismatch</p>
                                        <p className="text-xs text-rose-700">Warning: Assets do not equal Liabilities + Equity. Difference: {formatPKR(Math.abs(report.totalAssets - report.totalLiabilityAndEquity))}</p>
                                    </div>
                                </Card>
                            )}

                            <div className="bg-white border text-sm border-slate-200 rounded-xl overflow-hidden shadow-sm">
                                <table className="w-full border-collapse">
                                    <thead>
                                        <tr className="bg-slate-50 border-b border-slate-200">
                                            <th className="text-left px-6 py-3 text-[10px] font-black uppercase tracking-widest text-slate-500">Account</th>
                                            <th className="text-right px-6 py-3 text-[10px] font-black uppercase tracking-widest text-slate-500">Total (PKR)</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {/* ====== ASSETS ====== */}
                                        <tr className="bg-slate-900 text-white">
                                            <td colSpan={2} className="px-6 py-3 font-black uppercase tracking-widest text-sm">ASSETS</td>
                                        </tr>

                                        {/* CURRENT ASSETS */}
                                        <tr className="bg-slate-100">
                                            <td colSpan={2} className="px-8 py-2 font-black text-slate-700 uppercase text-xs tracking-widest">CURRENT ASSETS</td>
                                        </tr>

                                        {/* Cash */}
                                        {report.cashAccounts.length > 0 && (
                                            <>
                                                <tr className="bg-slate-50"><td colSpan={2} className="px-10 py-1.5 font-bold text-slate-500 uppercase text-[10px] tracking-widest">CASH</td></tr>
                                                {report.cashAccounts.map((a, i) => (
                                                    <tr key={`cash-${i}`} className="border-b border-slate-50">
                                                        <td className="px-14 py-2 text-slate-600 text-xs font-bold uppercase">{a.account_name}</td>
                                                        <td className="text-right px-6 py-2 tabular-nums font-bold">{formatNumber(a.balance)}</td>
                                                    </tr>
                                                ))}
                                                <tr className="font-bold bg-white">
                                                    <td className="px-10 py-2.5 uppercase text-slate-700 text-[10px] tracking-widest">TOTAL CASH</td>
                                                    <td className="text-right px-6 py-2.5 tabular-nums">{formatNumber(report.totalCash)}</td>
                                                </tr>
                                            </>
                                        )}

                                        {/* Bank */}
                                        {report.bankAccounts.length > 0 && (
                                            <>
                                                <tr className="bg-slate-50"><td colSpan={2} className="px-10 py-1.5 font-bold text-slate-500 uppercase text-[10px] tracking-widest">BANK</td></tr>
                                                {report.bankAccounts.map((a, i) => (
                                                    <tr key={`bank-${i}`} className="border-b border-slate-50">
                                                        <td className="px-14 py-2 text-slate-600 text-xs font-bold uppercase">{a.account_name}</td>
                                                        <td className="text-right px-6 py-2 tabular-nums font-bold">{formatNumber(a.balance)}</td>
                                                    </tr>
                                                ))}
                                                <tr className="font-bold bg-white">
                                                    <td className="px-10 py-2.5 uppercase text-slate-700 text-[10px] tracking-widest">TOTAL BANK</td>
                                                    <td className="text-right px-6 py-2.5 tabular-nums">{formatNumber(report.totalBank)}</td>
                                                </tr>
                                            </>
                                        )}

                                        {/* Inventory */}
                                        {report.inventoryAccounts.length > 0 && (
                                            <>
                                                <tr className="bg-slate-50"><td colSpan={2} className="px-10 py-1.5 font-bold text-slate-500 uppercase text-[10px] tracking-widest">INVENTORY</td></tr>
                                                {report.inventoryAccounts.map((a, i) => (
                                                    <tr key={`inv-${i}`} className="border-b border-slate-50">
                                                        <td className="px-14 py-2 text-slate-600 text-xs font-bold uppercase">{a.account_name}</td>
                                                        <td className="text-right px-6 py-2 tabular-nums font-bold">{formatNumber(a.balance)}</td>
                                                    </tr>
                                                ))}
                                                <tr className="font-bold bg-white">
                                                    <td className="px-10 py-2.5 uppercase text-slate-700 text-[10px] tracking-widest">TOTAL INVENTORY</td>
                                                    <td className="text-right px-6 py-2.5 tabular-nums">{formatNumber(report.totalInventory)}</td>
                                                </tr>
                                            </>
                                        )}

                                        {/* Other Current Assets */}
                                        {report.currentAssets.length > 0 && (
                                            <>
                                                <tr className="bg-slate-50"><td colSpan={2} className="px-10 py-1.5 font-bold text-slate-500 uppercase text-[10px] tracking-widest">OTHER CURRENT ASSETS</td></tr>
                                                {report.currentAssets.map((a, i) => (
                                                    <tr key={`ca-${i}`} className="border-b border-slate-50">
                                                        <td className="px-14 py-2 text-slate-600 text-xs font-bold uppercase">{a.account_name}</td>
                                                        <td className="text-right px-6 py-2 tabular-nums font-bold">{formatNumber(a.balance)}</td>
                                                    </tr>
                                                ))}
                                            </>
                                        )}

                                        <tr className="font-black border-y-2 border-slate-200 bg-slate-50">
                                            <td className="px-8 py-3 uppercase text-slate-800 text-xs tracking-widest">TOTAL CURRENT ASSETS</td>
                                            <td className="text-right px-6 py-3 tabular-nums">{formatNumber(report.totalCurrentAssets)}</td>
                                        </tr>

                                        {/* NON-CURRENT ASSETS */}
                                        <tr className="bg-slate-100">
                                            <td colSpan={2} className="px-8 py-2 font-black text-slate-700 uppercase text-xs tracking-widest">NON CURRENT ASSETS</td>
                                        </tr>
                                        {report.nonCurrentAssets.length > 0 && (
                                            <>
                                                {report.nonCurrentAssets.map((a, i) => (
                                                    <tr key={`nca-${i}`} className="border-b border-slate-50">
                                                        <td className="px-14 py-2 text-slate-600 text-xs font-bold uppercase">{a.account_name}</td>
                                                        <td className="text-right px-6 py-2 tabular-nums font-bold">{formatNumber(a.balance)}</td>
                                                    </tr>
                                                ))}
                                            </>
                                        )}
                                        <tr className="font-black border-y-2 border-slate-200 bg-slate-50">
                                            <td className="px-8 py-3 uppercase text-slate-800 text-xs tracking-widest">TOTAL NON CURRENT ASSETS</td>
                                            <td className="text-right px-6 py-3 tabular-nums">{formatNumber(report.totalNonCurrentAssets)}</td>
                                        </tr>

                                        {/* TOTAL ASSETS (GRAND) */}
                                        <tr className="font-black border-y-4 border-slate-900 bg-slate-100 text-lg text-emerald-800">
                                            <td className="px-6 py-4 uppercase tracking-[0.2em]">TOTAL ASSETS</td>
                                            <td className="text-right px-6 py-4 tabular-nums">{formatPKR(report.totalAssets)}</td>
                                        </tr>


                                        {/* ====== LIABILITIES & EQUITY ====== */}
                                        <tr className="bg-slate-900 text-white mt-8">
                                            <td colSpan={2} className="px-6 py-3 font-black uppercase tracking-widest text-sm">LIABILITIES AND EQUITY</td>
                                        </tr>

                                        {/* LIABILITIES */}
                                        <tr className="bg-slate-100">
                                            <td colSpan={2} className="px-8 py-2 font-black text-slate-700 uppercase text-xs tracking-widest">LIABILITIES</td>
                                        </tr>

                                        {/* Current Liabilities */}
                                        <tr className="bg-slate-50"><td colSpan={2} className="px-10 py-1.5 font-bold text-slate-500 uppercase text-[10px] tracking-widest">CURRENT LIABILITY</td></tr>
                                        {report.currentLiabilities.map((a, i) => (
                                            <tr key={`cl-${i}`} className="border-b border-slate-50">
                                                <td className="px-14 py-2 text-slate-600 text-xs font-bold uppercase">{a.account_name}</td>
                                                <td className="text-right px-6 py-2 tabular-nums font-bold">{formatNumber(a.balance)}</td>
                                            </tr>
                                        ))}
                                        <tr className="font-bold bg-white">
                                            <td className="px-10 py-2.5 uppercase text-slate-700 text-[10px] tracking-widest">TOTAL CURRENT LIABILITY</td>
                                            <td className="text-right px-6 py-2.5 tabular-nums">{formatNumber(report.totalCurrentLiability)}</td>
                                        </tr>

                                        {/* Long Term Liabilities */}
                                        <tr className="bg-slate-50"><td colSpan={2} className="px-10 py-1.5 font-bold text-slate-500 uppercase text-[10px] tracking-widest">LONG TERM LIABILITY</td></tr>
                                        {report.longTermLiabilities.map((a, i) => (
                                            <tr key={`ltl-${i}`} className="border-b border-slate-50">
                                                <td className="px-14 py-2 text-slate-600 text-xs font-bold uppercase">{a.account_name}</td>
                                                <td className="text-right px-6 py-2 tabular-nums font-bold">{formatNumber(a.balance)}</td>
                                            </tr>
                                        ))}
                                        <tr className="font-bold bg-white border-b-2 border-slate-200">
                                            <td className="px-10 py-2.5 uppercase text-slate-700 text-[10px] tracking-widest">TOTAL LONG TERM LIABILITY</td>
                                            <td className="text-right px-6 py-2.5 tabular-nums">{formatNumber(report.totalLongTermLiability)}</td>
                                        </tr>

                                        <tr className="font-black bg-slate-50 border-b-2 border-slate-200">
                                            <td className="px-8 py-3 uppercase text-slate-800 text-xs tracking-widest">TOTAL LIABILITIES</td>
                                            <td className="text-right px-6 py-3 tabular-nums">{formatNumber(report.totalLiabilities)}</td>
                                        </tr>

                                        {/* EQUITY */}
                                        <tr className="bg-slate-100">
                                            <td colSpan={2} className="px-8 py-2 font-black text-slate-700 uppercase text-xs tracking-widest">EQUITY</td>
                                        </tr>
                                        <tr className="bg-slate-50"><td colSpan={2} className="px-10 py-1.5 font-bold text-slate-500 uppercase text-[10px] tracking-widest">EQUITY</td></tr>
                                        {report.equityAccounts.map((a, i) => (
                                            <tr key={`eq-${i}`} className="border-b border-slate-50">
                                                <td className="px-14 py-2 text-slate-600 text-xs font-bold uppercase">{a.account_name}</td>
                                                <td className="text-right px-6 py-2 tabular-nums font-bold">{formatNumber(a.balance)}</td>
                                            </tr>
                                        ))}
                                        <tr className="font-bold bg-white">
                                            <td className="px-10 py-2.5 uppercase text-slate-700 text-[10px] tracking-widest">TOTAL EQUITY</td>
                                            <td className="text-right px-6 py-2.5 tabular-nums">{formatNumber(report.totalEquity)}</td>
                                        </tr>

                                        <tr className="font-black bg-slate-50 border-b-2 border-slate-200">
                                            <td className="px-8 py-3 uppercase text-slate-800 text-xs tracking-widest">TOTAL EQUITY</td>
                                            <td className="text-right px-6 py-3 tabular-nums">{formatNumber(report.totalEquity)}</td>
                                        </tr>

                                    </tbody>
                                    <tfoot>
                                        {/* TOTAL LIABILITIES & EQUITY (GRAND) */}
                                        <tr className="font-black border-y-4 border-slate-900 bg-slate-100 text-lg text-slate-900">
                                            <td className="px-6 py-4 uppercase tracking-[0.2em]">TOTAL LIABILITIES AND EQUITY</td>
                                            <td className="text-right px-6 py-4 tabular-nums">{formatPKR(report.totalLiabilityAndEquity)}</td>
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
