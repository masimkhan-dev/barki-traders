import { useQuery } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { Card, CardHeader, CardTitle, CardContent } from "@/components/ui/card";
import { Loader2, Download } from 'lucide-react';
import { formatPKR } from '@/lib/format';
import { Button } from '@/components/ui/button';

interface DrawingsReportProps {
    startDate: string;
    endDate: string;
}

export function DrawingsReport({ startDate, endDate }: DrawingsReportProps) {
    const accountSlug = 'owner_drawings';

    const { data, isLoading } = useQuery({
        queryKey: ['drawings-report', startDate, endDate],
        queryFn: async () => {
            // 1. Get Account ID for Owner Drawings
            const { data: accData, error: accError } = await supabase
                .from('accounts')
                .select('id')
                .eq('slug', accountSlug)
                .single();

            if (accError) throw accError;
            if (!accData) return [];

            // 2. Fetch Ledger Entries for this account
            const { data: entries, error: entriesError } = await supabase
                .from('ledger_entries')
                .select(`
          id,
          voucher_no,
          posting_date,
          narration,
          debit_amount
        `)
                .eq('account_id', accData.id)
                .gte('posting_date', startDate)
                .lte('posting_date', endDate)
                .order('posting_date', { ascending: false });

            if (entriesError) throw entriesError;
            return entries;
        },
        enabled: !!startDate && !!endDate
    });

    const totalDrawings = data ? data.reduce((sum, item) => sum + Number(item.debit_amount), 0) : 0;

    const handlePrint = () => {
        window.print();
    };

    if (isLoading) {
        return <div className="flex justify-center p-12"><Loader2 className="h-8 w-8 animate-spin text-muted-foreground" /></div>;
    }

    return (
        <div className="space-y-6 animate-in fade-in slide-in-from-bottom-5">
            {/* Action Bar */}
            <div className="flex justify-between items-center bg-white p-4 rounded-lg border shadow-sm">
                <div className="text-sm font-medium text-muted-foreground">
                    Report Period: <span className="text-foreground">{startDate}</span> to <span className="text-foreground">{endDate}</span>
                </div>
                <Button onClick={handlePrint} variant="outline" size="sm">
                    <Download className="mr-2 h-4 w-4" /> Print Report
                </Button>
            </div>

            {/* Summary Card */}
            <Card className="bg-orange-50 border-orange-200">
                <CardHeader className="pb-2">
                    <CardTitle className="text-sm font-medium text-orange-700">Total Owner Withdrawals</CardTitle>
                </CardHeader>
                <CardContent>
                    <div className="text-3xl font-bold text-orange-800">{formatPKR(totalDrawings)}</div>
                    <p className="text-sm text-muted-foreground mt-1">Total amount withdrawn for personal use in selected period.</p>
                </CardContent>
            </Card>

            {/* Detail Table */}
            <Card>
                <CardHeader>
                    <CardTitle>Withdrawal History</CardTitle>
                </CardHeader>
                <CardContent>
                    <div className="relative w-full overflow-auto">
                        <table className="w-full text-sm text-left">
                            <thead className="bg-muted/50 text-muted-foreground sticky top-0">
                                <tr>
                                    <th className="p-3 w-[120px]">Date</th>
                                    <th className="p-3 w-[150px]">Voucher #</th>
                                    <th className="p-3">Description</th>
                                    <th className="p-3 text-right">Amount (PKR)</th>
                                </tr>
                            </thead>
                            <tbody className="divide-y">
                                {data?.map((item) => (
                                    <tr key={item.id} className="hover:bg-muted/50">
                                        <td className="p-3 font-medium">{item.posting_date}</td>
                                        <td className="p-3 font-mono text-xs text-muted-foreground">{item.voucher_no}</td>
                                        <td className="p-3">{item.narration || 'Owner Withdrawal'}</td>
                                        <td className="p-3 text-right font-bold text-orange-700">{formatPKR(item.debit_amount)}</td>
                                    </tr>
                                ))}
                                {(!data || data.length === 0) && (
                                    <tr>
                                        <td colSpan={4} className="p-8 text-center text-muted-foreground">
                                            No withdrawals found in this period.
                                        </td>
                                    </tr>
                                )}
                            </tbody>
                            {/* Grand Total Row */}
                            {data && data.length > 0 && (
                                <tfoot className="bg-muted/30 font-bold border-t-2">
                                    <tr>
                                        <td colSpan={3} className="p-3 text-right">Total Withdrawals:</td>
                                        <td className="p-3 text-right text-orange-800">{formatPKR(totalDrawings)}</td>
                                    </tr>
                                </tfoot>
                            )}
                        </table>
                    </div>
                </CardContent>
            </Card>
        </div>
    );
}
