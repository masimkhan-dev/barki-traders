import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { supabase } from '@/integrations/supabase/client';
import { formatPKR, formatNumber } from '@/lib/format';
import { Button } from '@/components/ui/button';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import { Card } from '@/components/ui/card';
import {
    Printer,
    Download,
    Search,
    ShoppingCart,
    Truck,
    Wallet,
    Calendar,
    ArrowUpRight,
    ArrowDownLeft,
    Loader2
} from 'lucide-react';

// Helper: Classic Date Format (DD-MM-YY)
const formatClassicDate = (dateStr: string | null | undefined): string => {
    if (!dateStr) return '-';
    const d = new Date(dateStr);
    const day = String(d.getDate()).padStart(2, '0');
    const month = String(d.getMonth() + 1).padStart(2, '0');
    const year = String(d.getFullYear()).slice(-2);
    return `${day}-${month}-${year}`;
};

// Helper: CSV Export
const exportToCSV = (data: any[], filename: string) => {
    if (!data || data.length === 0) return;
    const headers = Object.keys(data[0]).join(',');
    const rows = data.map(row =>
        Object.values(row).map(val =>
            typeof val === 'string' ? `"${val.replace(/"/g, '""')}"` : val
        ).join(',')
    );
    const csvContent = [headers, ...rows].join('\n');
    const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
    const link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = `${filename}_${new Date().toISOString().split('T')[0]}.csv`;
    link.click();
};

export default function BusinessReports() {
    const today = new Date();
    const firstDay = new Date(today.getFullYear(), today.getMonth(), 1);

    const [startDate, setStartDate] = useState<string>(firstDay.toISOString().split('T')[0]);
    const [endDate, setEndDate] = useState<string>(today.toISOString().split('T')[0]);
    const [activeReport, setActiveReport] = useState<string>('sales');

    // SALES REPORT DATA
    const { data: sales, isLoading: loadingSales } = useQuery({
        queryKey: ['report-sales', startDate, endDate],
        queryFn: async () => {
            const { data, error } = await supabase
                .from('sales')
                .select(`
                    *,
                    party:parties(name),
                    fuel:fuel_types(name)
                `)
                .gte('sale_date', startDate)
                .lte('sale_date', endDate)
                .order('sale_date', { ascending: false });
            if (error) throw error;
            return data;
        },
        staleTime: 0
    });

    // PURCHASE REPORT DATA
    const { data: purchases, isLoading: loadingPurchases } = useQuery({
        queryKey: ['report-purchases', startDate, endDate],
        queryFn: async () => {
            const { data, error } = await supabase
                .from('purchases')
                .select(`
                    *,
                    party:parties(name),
                    fuel:fuel_types(name)
                `)
                .gte('purchase_date', startDate)
                .lte('purchase_date', endDate)
                .order('purchase_date', { ascending: false });
            if (error) throw error;
            return data;
        },
        staleTime: 0
    });

    // PAYMENT REPORT DATA (Using RPC for accurate money movement)
    const { data: payments, isLoading: loadingPayments } = useQuery({
        queryKey: ['report-payments-rpc', startDate, endDate],
        queryFn: async () => {
            const { data, error } = await (supabase as any).rpc('get_payments_report', {
                p_start_date: startDate,
                p_end_date: endDate
            });
            if (error) throw error;
            return data as any[];
        },
    });

    // MARKET POSITION DATA (V11 Combined Report)
    const { data: marketPosition, isLoading: loadingMarket } = useQuery({
        queryKey: ['report-market-position', endDate],
        queryFn: async () => {
            const { data, error } = await (supabase as any).rpc('get_market_position_report', {
                p_as_of_date: endDate
            });
            if (error) throw error;
            return data as any[];
        },
    });

    // DRAWINGS REPORT DATA
    const { data: drawings, isLoading: loadingDrawings } = useQuery({
        queryKey: ['report-drawings', startDate, endDate],
        queryFn: async () => {
            const { data: acc } = await supabase.from('accounts').select('id').eq('slug', 'owner_drawings').single();
            if (!acc) return [];

            const { data, error } = await supabase
                .from('ledger_entries')
                .select('*')
                .eq('account_id', acc.id)
                .gte('posting_date', startDate)
                .lte('posting_date', endDate)
                .order('posting_date', { ascending: false });
            if (error) throw error;
            return data;
        },
        staleTime: 0
    });

    return (

        <DashboardLayout>
            <div className="max-w-7xl mx-auto pb-20 print:p-0">

                {/* STICKY FILTER BAR */}
                <div className="sticky-filter-bar print:hidden px-4">
                    <div className="max-w-7xl mx-auto flex flex-wrap items-center justify-between gap-4">
                        <div className="report-header mb-0">
                            <h1 className="report-title">Naveed Musazai</h1>
                            <p className="report-subtitle">Transactional Analysis & Audit Center</p>
                        </div>

                        <div className="flex flex-wrap items-center gap-3 bg-slate-50 p-2 border border-slate-200 rounded-sm">
                            <div className="flex flex-col">
                                <label className="text-[9px] font-bold uppercase text-slate-500 mb-1">Start Date</label>
                                <input type="date" value={startDate} onChange={e => setStartDate(e.target.value)} className="h-8 px-2 border border-slate-300 rounded-none font-bold text-xs" />
                            </div>
                            <div className="flex flex-col">
                                <label className="text-[9px] font-bold uppercase text-slate-500 mb-1">End Date</label>
                                <input type="date" value={endDate} onChange={e => setEndDate(e.target.value)} className="h-8 px-2 border border-slate-300 rounded-none font-bold text-xs" />
                            </div>
                            <div className="flex gap-2 ml-2">
                                <Button variant="outline" size="icon" className="h-8 w-8 rounded-none border-slate-300" onClick={() => window.print()} title="Print Statement">
                                    <Printer className="h-3.5 w-3.5" />
                                </Button>
                                <Button variant="outline" size="icon" className="h-8 w-8 rounded-none border-slate-300" onClick={() => {
                                    let data = activeReport === 'sales' ? sales : activeReport === 'purchases' ? purchases : payments;
                                    let csvData = data;
                                    if (activeReport === 'payments' && payments) {
                                        csvData = (payments as any[]).map(row => ({
                                            Date: row.posting_date,
                                            Voucher: row.voucher_no,
                                            From: row.from_name,
                                            To: row.to_name,
                                            Amount: row.amount,
                                            Narration: row.narration
                                        })) as any;
                                    }
                                    exportToCSV((csvData as any[]) || [], activeReport + '_report');
                                }} title="Export CSV">
                                    <Download className="h-3.5 w-3.5" />
                                </Button>
                            </div>
                        </div>
                    </div>
                </div>

                <div className="px-4 space-y-8">
                    <Tabs value={activeReport} onValueChange={setActiveReport} className="space-y-6">
                        <TabsList className="bg-slate-100 p-0 rounded-none h-10 border border-slate-300 w-full lg:max-w-2xl grid grid-cols-5 print:hidden">
                            <TabsTrigger value="sales" className="rounded-none border-r border-slate-300 font-bold uppercase text-[10px] tracking-widest data-[state=active]:bg-slate-900 data-[state=active]:text-white h-full transition-none">Sales</TabsTrigger>
                            <TabsTrigger value="purchases" className="rounded-none border-r border-slate-300 font-bold uppercase text-[10px] tracking-widest data-[state=active]:bg-slate-900 data-[state=active]:text-white h-full transition-none">Purchases</TabsTrigger>
                            <TabsTrigger value="payments" className="rounded-none border-r border-slate-300 font-bold uppercase text-[10px] tracking-widest data-[state=active]:bg-slate-900 data-[state=active]:text-white h-full transition-none">Payments</TabsTrigger>
                            <TabsTrigger value="market" className="rounded-none border-r border-slate-300 font-bold uppercase text-[10px] tracking-widest data-[state=active]:bg-slate-900 data-[state=active]:text-white h-full transition-none">Market Position</TabsTrigger>
                            <TabsTrigger value="drawings" className="rounded-none font-bold uppercase text-[10px] tracking-widest data-[state=active]:bg-slate-900 data-[state=active]:text-white h-full transition-none">Drawings</TabsTrigger>
                        </TabsList>

                        {/* SUMMARY CARDS FOR CONTEXT */}
                        <div className="grid grid-cols-2 md:grid-cols-4 gap-4 print:hidden">
                            {activeReport === 'sales' && (
                                <>
                                    <div className="summary-card">
                                        <span className="summary-label">Total Volume (L)</span>
                                        <span className="summary-value num-audit">{formatNumber(sales?.reduce((s, r) => s + (Number(r.quantity) || 0), 0) || 0)}</span>
                                    </div>
                                    <div className="summary-card">
                                        <span className="summary-label">Total Revenue</span>
                                        <span className="summary-value text-assets">{formatPKR(sales?.reduce((s, r) => s + (Number(r.total_amount) || 0), 0) || 0)}</span>
                                    </div>
                                </>
                            )}
                            {activeReport === 'purchases' && (
                                <>
                                    <div className="summary-card">
                                        <span className="summary-label">Purchase Volume (L)</span>
                                        <span className="summary-value num-audit">{formatNumber(purchases?.reduce((s, r) => s + (Number(r.quantity) || 0), 0) || 0)}</span>
                                    </div>
                                    <div className="summary-card">
                                        <span className="summary-label">Procurement Cost</span>
                                        <span className="summary-value text-liabilities">{formatPKR(purchases?.reduce((s, r) => s + (Number(r.total_amount) || 0), 0) || 0)}</span>
                                    </div>
                                </>
                            )}
                            {activeReport === 'payments' && (
                                <div className="summary-card">
                                    <span className="summary-label">Cash/Bank Flow</span>
                                    <span className="summary-value text-slate-900">{formatPKR(payments?.reduce((s, r) => s + (Number(r.amount) || 0), 0) || 0)}</span>
                                </div>
                            )}
                            {activeReport === 'drawings' && (
                                <div className="summary-card border-orange-200">
                                    <span className="summary-label text-orange-600">Total Withdrawals</span>
                                    <span className="summary-value text-orange-700">{formatPKR(drawings?.reduce((s, r) => s + (Number(r.debit_amount) || 0), 0) || 0)}</span>
                                </div>
                            )}
                            {activeReport === 'market' && (
                                <>
                                    <div className="summary-card rounded-none shadow-none border border-slate-200">
                                        <span className="summary-label text-assets">Total Receivables (Lena)</span>
                                        <span className="summary-value text-assets">{formatPKR(marketPosition?.reduce((s, r) => s + (Number(r.receivable_balance) || 0), 0) || 0)}</span>
                                    </div>
                                    <div className="summary-card rounded-none shadow-none border border-slate-200">
                                        <span className="summary-label text-liabilities">Total Payables (Dena)</span>
                                        <span className="summary-value text-liabilities">{formatPKR(marketPosition?.reduce((s, r) => s + (Number(r.payable_balance) || 0), 0) || 0)}</span>
                                    </div>
                                </>
                            )}
                        </div>

                        {/* SALES REPORT */}
                        <TabsContent value="sales" className="m-0">
                            <div className="border border-slate-300 overflow-hidden">
                                <table className="ledger-table">
                                    <thead>
                                        <tr>
                                            <th className="w-24">Date</th>
                                            <th className="w-24">Voucher</th>
                                            <th>Customer Name</th>
                                            <th className="w-32">Product</th>
                                            <th className="right-align w-32">Qty (L)</th>
                                            <th className="right-align w-32">Rate</th>
                                            <th className="right-align w-40">Total Amount</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {loadingSales ? (
                                            <tr>
                                                <td colSpan={7} className="py-24 bg-slate-50/50">
                                                    <div className="flex flex-col items-center justify-center gap-4">
                                                        <Loader2 className="h-8 w-8 animate-spin text-slate-400" />
                                                        <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-500">Auditing Sales Activity...</span>
                                                    </div>
                                                </td>
                                            </tr>
                                        ) : sales?.map((row, i) => (
                                            <tr key={i}>
                                                <td>{formatClassicDate(row.sale_date)}</td>
                                                <td className="num-audit !text-[10px] text-slate-400">{row.voucher_no}</td>
                                                <td className="font-bold uppercase">{row.party?.name}</td>
                                                <td className="font-bold text-slate-600 italic">{row.fuel?.name}</td>
                                                <td className="right-align num-audit font-bold">{formatNumber(row.quantity)}</td>
                                                <td className="right-align num-audit text-slate-400">{formatNumber(row.rate_per_unit)}</td>
                                                <td className="right-align num-audit font-bold text-assets">{formatNumber(row.total_amount)}</td>
                                            </tr>
                                        ))}
                                    </tbody>
                                    <tfoot className="bg-slate-50 font-black">
                                        <tr className="border-t-2 border-slate-900">
                                            <td colSpan={6} className="px-4 py-3 right-align uppercase text-xs">Gross Sales for Period:</td>
                                            <td className="px-4 py-3 right-align text-xl text-assets num-audit underline decoration-double">{formatPKR(sales?.reduce((s, r) => s + (Number(r.total_amount) || 0), 0) || 0)}</td>
                                        </tr>
                                    </tfoot>
                                </table>
                            </div>
                        </TabsContent>

                        {/* PURCHASE REPORT */}
                        <TabsContent value="purchases" className="m-0">
                            <div className="border border-slate-300 overflow-hidden">
                                <table className="ledger-table">
                                    <thead>
                                        <tr>
                                            <th className="w-24">Date</th>
                                            <th className="w-24">Voucher</th>
                                            <th>Supplier Name</th>
                                            <th className="w-32">Product</th>
                                            <th className="right-align w-32">Qty (L)</th>
                                            <th className="right-align w-32">Rate</th>
                                            <th className="right-align w-40">Total Amount</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {loadingPurchases ? (
                                            <tr>
                                                <td colSpan={7} className="py-24 bg-slate-50/50">
                                                    <div className="flex flex-col items-center justify-center gap-4">
                                                        <Loader2 className="h-8 w-8 animate-spin text-slate-400" />
                                                        <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-500">Auditing Purchase Records...</span>
                                                    </div>
                                                </td>
                                            </tr>
                                        ) : purchases?.map((row, i) => (
                                            <tr key={i}>
                                                <td>{formatClassicDate(row.purchase_date)}</td>
                                                <td className="num-audit !text-[10px] text-slate-400">{row.voucher_no}</td>
                                                <td className="font-bold uppercase">{row.party?.name}</td>
                                                <td className="font-bold text-slate-600 italic">{row.fuel?.name}</td>
                                                <td className="right-align num-audit font-bold">{formatNumber(row.quantity)}</td>
                                                <td className="right-align num-audit text-slate-400">{formatNumber(row.rate_per_unit)}</td>
                                                <td className="right-align num-audit font-bold text-liabilities">{formatNumber(row.total_amount)}</td>
                                            </tr>
                                        ))}
                                    </tbody>
                                    <tfoot className="bg-slate-50 font-black">
                                        <tr className="border-t-2 border-slate-900">
                                            <td colSpan={6} className="px-4 py-3 right-align uppercase text-xs">Gross Procurement for Period:</td>
                                            <td className="px-4 py-3 right-align text-xl text-liabilities num-audit underline decoration-double">{formatPKR(purchases?.reduce((s, r) => s + (Number(r.total_amount) || 0), 0) || 0)}</td>
                                        </tr>
                                    </tfoot>
                                </table>
                            </div>
                        </TabsContent>

                        {/* PAYMENT REPORT */}
                        <TabsContent value="payments" className="m-0">
                            <div className="border border-slate-300 overflow-hidden">
                                <table className="ledger-table">
                                    <thead>
                                        <tr>
                                            <th className="w-24">Date</th>
                                            <th className="w-32 center-align">Voucher No</th>
                                            <th>Transfer From (Source)</th>
                                            <th>Transfer To (Destination)</th>
                                            <th className="right-align w-48">Amount (PKR)</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {loadingPayments ? (
                                            <tr>
                                                <td colSpan={5} className="py-24 bg-slate-50/50">
                                                    <div className="flex flex-col items-center justify-center gap-4">
                                                        <Loader2 className="h-8 w-8 animate-spin text-slate-400" />
                                                        <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-500">Tracing Cash Flows...</span>
                                                    </div>
                                                </td>
                                            </tr>
                                        ) : payments?.map((row, i) => (
                                            <tr key={i}>
                                                <td>{formatClassicDate(row.posting_date)}</td>
                                                <td className="num-audit !text-[10px] center-align text-slate-400">{row.voucher_no}</td>
                                                <td className="font-bold uppercase">{row.from_name}</td>
                                                <td className="font-bold uppercase text-blue-900">{row.to_name}</td>
                                                <td className="right-align num-audit font-bold">{formatNumber(row.amount)}</td>
                                            </tr>
                                        ))}
                                    </tbody>
                                    <tfoot className="bg-slate-50 font-black">
                                        <tr className="border-t-2 border-slate-900">
                                            <td colSpan={4} className="px-4 py-3 right-align uppercase text-xs">Total Transactional Value:</td>
                                            <td className="px-4 py-3 right-align text-xl text-slate-900 num-audit underline decoration-double">{formatPKR(payments?.reduce((s, r) => s + (Number(r.amount) || 0), 0) || 0)}</td>
                                        </tr>
                                    </tfoot>
                                </table>
                            </div>
                        </TabsContent>

                        {/* MARKET POSITION REPORT (V11) */}
                        <TabsContent value="market" className="m-0">
                            <div className="border border-slate-300 overflow-hidden">
                                <table className="ledger-table shadow-none">
                                    <thead>
                                        <tr>
                                            <th>Party Name</th>
                                            <th className="w-32 center-align">Type</th>
                                            <th className="right-align w-48">Receivable (Lena)</th>
                                            <th className="right-align w-48">Payable (Dena)</th>
                                            <th className="right-align w-32">Last Entry</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {loadingMarket ? (
                                            <tr>
                                                <td colSpan={5} className="py-24 bg-slate-50/50">
                                                    <div className="flex flex-col items-center justify-center gap-4">
                                                        <Loader2 className="h-8 w-8 animate-spin text-slate-400" />
                                                        <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-500">Calculating Market Position...</span>
                                                    </div>
                                                </td>
                                            </tr>
                                        ) : marketPosition?.map((row, i) => (
                                            <tr key={i} className="hover:bg-transparent">
                                                <td className="font-bold uppercase">{row.party_name}</td>
                                                <td className="center-align text-[9px] font-black uppercase text-slate-400 tracking-tighter">{row.party_type}</td>
                                                <td className="right-align num-audit font-bold text-assets">{row.receivable_balance > 0 ? formatNumber(row.receivable_balance) : '-'}</td>
                                                <td className="right-align num-audit font-bold text-liabilities">{row.payable_balance > 0 ? formatNumber(row.payable_balance) : '-'}</td>
                                                <td className="right-align num-audit text-[10px] text-slate-400">{formatClassicDate(row.last_transaction_date)}</td>
                                            </tr>
                                        ))}
                                    </tbody>
                                    <tfoot className="bg-slate-50 font-black">
                                        <tr className="border-t-2 border-slate-900 border-b-2">
                                            <td colSpan={2} className="px-4 py-3 right-align uppercase text-xs">Net Market Exposure:</td>
                                            <td colSpan={2} className="px-4 py-3 right-align text-xl text-slate-900 num-audit underline decoration-double">
                                                {formatPKR(
                                                    (marketPosition?.reduce((s, r) => s + (Number(r.receivable_balance) || 0), 0) || 0) -
                                                    (marketPosition?.reduce((s, r) => s + (Number(r.payable_balance) || 0), 0) || 0)
                                                )}
                                            </td>
                                            <td></td>
                                        </tr>
                                    </tfoot>
                                </table>
                            </div>
                        </TabsContent>

                        {/* DRAWINGS REPORT (NEW) */}
                        <TabsContent value="drawings" className="m-0">
                            <div className="border border-slate-300 overflow-hidden">
                                <table className="ledger-table">
                                    <thead>
                                        <tr>
                                            <th className="w-24">Date</th>
                                            <th className="w-32 center-align">Voucher No</th>
                                            <th>Description / Narration</th>
                                            <th className="right-align w-48">Amount (PKR)</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {loadingDrawings ? (
                                            <tr>
                                                <td colSpan={4} className="py-24 bg-slate-50/50">
                                                    <div className="flex flex-col items-center justify-center gap-4">
                                                        <Loader2 className="h-8 w-8 animate-spin text-slate-400" />
                                                        <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-500">Retrieving Withdrawals...</span>
                                                    </div>
                                                </td>
                                            </tr>
                                        ) : drawings?.map((row, i) => (
                                            <tr key={i}>
                                                <td>{formatClassicDate(row.posting_date)}</td>
                                                <td className="num-audit !text-[10px] center-align text-slate-400">{row.voucher_no}</td>
                                                <td className="font-bold uppercase">{row.narration || 'Owner Withdrawal'}</td>
                                                <td className="right-align num-audit font-bold text-orange-700">{formatNumber(row.debit_amount)}</td>
                                            </tr>
                                        ))}
                                    </tbody>
                                    <tfoot className="bg-slate-50 font-black">
                                        <tr className="border-t-2 border-slate-900">
                                            <td colSpan={3} className="px-4 py-3 right-align uppercase text-xs">Total Withdrawals for Period:</td>
                                            <td className="px-4 py-3 right-align text-xl text-orange-700 num-audit underline decoration-double">{formatPKR(drawings?.reduce((s, r) => s + (Number(r.debit_amount) || 0), 0) || 0)}</td>
                                        </tr>
                                    </tfoot>
                                </table>
                            </div>
                        </TabsContent>
                    </Tabs>

                </div>
            </div>
        </DashboardLayout>

    );
}
