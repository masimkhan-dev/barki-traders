import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { supabase } from '@/integrations/supabase/client';
import { formatPKR, formatNumber } from '@/lib/format';
import { Button } from '@/components/ui/button';
import { addMonths, startOfMonth, endOfMonth, format } from 'date-fns';
import {
    Printer,
    UserCircle2,
    Building2,
    Loader2,
    TrendingUp,
    TrendingDown,
    Shield
} from 'lucide-react';
import { cn } from '@/lib/utils';

export default function CapitalReport() {
    const today = new Date();
    const [startDate, setStartDate] = useState(() => startOfMonth(today).toISOString().split('T')[0]);
    const [endDate, setEndDate] = useState(() => endOfMonth(today).toISOString().split('T')[0]);

    const { data: capitalTx, isLoading: loadingCapital } = useQuery({
        queryKey: ['capital-report', startDate, endDate],
        queryFn: async () => {
            const { data, error } = await (supabase.rpc as any)('get_owner_capital_report_v11', {
                p_start_date: startDate,
                p_end_date: endDate
            });
            if (error) {
                console.error("RPC ERROR (Capital Report):", error);
                throw error;
            }
            return data as any[];
        }
    });

    const { data: assets, isLoading: loadingAssets } = useQuery({
        queryKey: ['fixed-assets-report'],
        queryFn: async () => {
            const { data, error } = await (supabase.rpc as any)('get_fixed_assets_report_v11');
            if (error) throw error;
            return data as any[];
        }
    });

    const closingBalance = capitalTx && capitalTx.length > 0 ? capitalTx[capitalTx.length - 1].running_balance : 0;
    const totalDrawings = capitalTx?.reduce((acc, t) => acc + (Number(t.debit) || 0), 0) || 0;
    const totalInvestment = capitalTx?.reduce((acc, t) => acc + (Number(t.credit) || 0), 0) || 0;

    return (
        <DashboardLayout>
            <div className="max-w-7xl mx-auto pb-20 px-4 py-8 print:p-0">

                {/* V11 GOV HEADER */}
                <div className="flex flex-col md:flex-row justify-between items-start md:items-end border-b-4 border-slate-900 pb-6 mb-8 gap-4">
                    <div className="report-header mb-0 border-0 pb-0">
                        <h1 className="report-title">Proprietor's Equity Statement</h1>
                        <p className="report-subtitle">Personal Capital movement & business asset valuation</p>
                    </div>
                </div>

                {/* COMING SOON BANNER */}
                <div className="flex flex-col items-center justify-center py-32 bg-slate-50 border-4 border-dashed border-slate-200 shadow-inner">
                    <Shield className="h-16 w-16 text-slate-300 mb-6 animate-pulse" />
                    <h2 className="text-4xl font-black text-slate-900 uppercase tracking-tighter mb-4">
                        Coming Soon
                    </h2>
                    <p className="text-sm font-bold text-slate-500 uppercase tracking-[0.2em] max-w-md text-center leading-relaxed">
                        We are currently re-aligning the ledger architecture for 100% audit integrity.
                        This report will be restored once the reconciliation is complete.
                    </p>
                    <div className="mt-10 px-6 py-2 bg-slate-900 text-white text-[10px] font-black uppercase tracking-[0.4em]">
                        Final Audit in Progress
                    </div>
                </div>

            </div>
        </DashboardLayout>
    );
}
