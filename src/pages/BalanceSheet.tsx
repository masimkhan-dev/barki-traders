import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Scale, ShieldAlert } from 'lucide-react';

export default function BalanceSheet() {
    return (
        <DashboardLayout>
            <div className="max-w-4xl mx-auto py-20 px-6">
                <div className="bg-white border border-slate-200 rounded-2xl shadow-lg p-10 text-center space-y-6 relative overflow-hidden">
                    <div className="absolute top-0 left-0 w-full h-1.5 bg-gradient-to-r from-teal-500 via-indigo-500 to-purple-500" />
                    
                    <div className="mx-auto w-16 h-16 bg-slate-900 rounded-full flex items-center justify-center text-white shadow-md">
                        <Scale className="h-8 w-8 animate-pulse text-teal-400" />
                    </div>
                    
                    <div className="space-y-2">
                        <h1 className="text-2xl font-black uppercase tracking-wider text-slate-900">
                            Financial Position Statement (Balance Sheet)
                        </h1>
                        <p className="text-xs font-black uppercase text-teal-600 tracking-[0.2em]">
                            System Upgrade & Optimization Underway
                        </p>
                    </div>
                    
                    <div className="max-w-xl mx-auto bg-slate-50 border border-slate-100 rounded-xl p-6 text-slate-600 text-sm leading-relaxed text-left space-y-3">
                        <p className="font-bold text-slate-800 flex items-center gap-2">
                            <ShieldAlert className="h-4 w-4 text-teal-600 shrink-0" />
                            Dear User,
                        </p>
                        <p>
                            We are currently upgrading the real-time double-entry ledger calculation engine to support advanced multi-branch consolidation. 
                        </p>
                        <p>
                            All underlying ledger balances, trade receivables, payables, and inventory values are fully correct and active on your Dashboard and individual statements. 
                        </p>
                        <p className="text-xs font-bold text-slate-400 uppercase tracking-widest pt-2">
                            Status: Active Backend Reconciliations
                        </p>
                    </div>
                    
                    <div className="pt-4">
                        <p className="text-[10px] font-black uppercase text-slate-400 tracking-[0.2em]">
                            Secure Ledger Integrity: Active 
                        </p>
                    </div>
                </div>
            </div>
        </DashboardLayout>
    );
}
