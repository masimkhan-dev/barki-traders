import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { supabase } from '@/integrations/supabase/client';
import { formatPKR } from '@/lib/format';
import { Button } from '@/components/ui/button';
import { Card } from '@/components/ui/card';
import {
    Lock,
    ShieldAlert,
    ArrowRightLeft,
    Calendar,
    Loader2,
    CheckCircle2,
    ChevronRight
} from 'lucide-react';
import { useAuth } from '@/contexts/AuthContext';
import { toast } from 'sonner';

export default function MonthEndClosing() {
    const { user } = useAuth();
    const [selectedMonth, setSelectedMonth] = useState(() => {
        const now = new Date();
        return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
    });
    const [voucherNo, setVoucherNo] = useState(`CL-${Date.now().toString().slice(-6)}`);
    const [isExecuting, setIsExecuting] = useState(false);

    const startDate = `${selectedMonth}-01`;
    const endDate = new Date(new Date(startDate).getFullYear(), new Date(startDate).getMonth() + 1, 0).toISOString().split('T')[0];

    const { data: pnl, isLoading } = useQuery({
        queryKey: ['closing-preview-v11', selectedMonth],
        queryFn: async () => {
            const { data, error } = await (supabase.rpc as any)('get_profit_loss_v11', {
                p_start_date: startDate,
                p_end_date: endDate
            });
            if (error) throw error;

            const rows = (data || []) as any[];
            const income = rows.filter(r => r.section === 'Income').reduce((sum, r) => sum + Number(r.amount), 0);
            const expense = rows.filter(r => r.section === 'Direct Costs' || r.section === 'Expenses').reduce((sum, r) => sum + Number(r.amount), 0);
            return { income, expense, profit: income - expense };
        }
    });

    const handleExecute = async () => {
        if (!window.confirm(`Are you sure you want to close the month ${selectedMonth}? This will transfer ${formatPKR(pnl?.profit || 0)} to Owner Capital.`)) return;

        setIsExecuting(true);
        try {
            const { data, error } = await (supabase.rpc as any)('execute_month_end_closing', {
                p_month_year: selectedMonth,
                p_voucher_no: voucherNo,
                p_closing_date: new Date().toISOString().split('T')[0],
                p_user_id: user?.id
            });

            if (error) throw error;
            if (data.success) {
                toast.success(`Success: ${data.message || 'Month closed and profit transferred.'}`);
                setVoucherNo(`CL-${Date.now().toString().slice(-6)}`);
            } else {
                toast.error(data.message);
            }
        } catch (err: any) {
            toast.error(err.message || "Failed to execute closing.");
        } finally {
            setIsExecuting(false);
        }
    };

    return (
        <DashboardLayout>
            <div className="max-w-4xl mx-auto py-10 px-4 space-y-10">
                <div className="report-header border-b-2 border-slate-900 pb-6 mb-0">
                    <h1 className="report-title">Financial Period Closing</h1>
                    <p className="report-subtitle">P&L NIL Reset & Equity Transfer Utility</p>
                </div>

                {/* COMING SOON BANNER */}
                <div className="flex flex-col items-center justify-center py-24 bg-slate-50 border-4 border-dashed border-slate-200">
                    <Lock className="h-16 w-16 text-slate-300 mb-6 animate-pulse" />
                    <h2 className="text-4xl font-black text-slate-900 uppercase tracking-tighter mb-4">
                        Coming Soon
                    </h2>
                    <p className="text-xs font-bold text-slate-500 uppercase tracking-[0.2em] max-w-sm text-center leading-relaxed">
                        Month-end closing and Profit transfer features are temporarily offline for calibration.
                    </p>
                    <div className="mt-8 px-6 py-2 bg-slate-900 text-white text-[10px] font-black uppercase tracking-[0.4em]">
                        System Hardening in Progress
                    </div>
                </div>

                <div className="bg-slate-900 text-white p-6 grid grid-cols-1 md:grid-cols-3 gap-8 opacity-50">
                    <div className="space-y-2">
                        <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Rule #1</span>
                        <p className="text-[11px] font-bold text-slate-300">NIL reporting ensures that next month starts with fresh income/expense counters.</p>
                    </div>
                    <div className="space-y-2">
                        <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Rule #2</span>
                        <p className="text-[11px] font-bold text-slate-300">All historical Profit/Loss remains fully auditable through the Owner's Capital Report.</p>
                    </div>
                    <div className="space-y-2">
                        <span className="text-[10px] font-black text-slate-500 uppercase tracking-widest">Rule #3</span>
                        <p className="text-[11px] font-bold text-slate-300">Retroactive edits after closing will cause a discrepancy that must be cleared by a fresh closing.</p>
                    </div>
                </div>
            </div>
        </DashboardLayout>
    );
}

function SettingsIcon({ className }: { className?: string }) {
    return (
        <svg xmlns="http://www.w3.org/2000/svg" className={className} width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z" />
            <circle cx="12" cy="12" r="3" />
        </svg>
    );
}
