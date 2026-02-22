import { useState, useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { supabase } from '@/integrations/supabase/client';
import { Loader2, Folder, FileText, ChevronDown, ChevronRight, Landmark } from 'lucide-react';
import { Card } from '@/components/ui/card';
import { cn } from '@/lib/utils';

interface Account {
    id: string;
    name: string;
    code: string;
    account_type: string;
    is_active?: boolean;
}

export default function ChartOfAccounts() {
    const { data: accounts, isLoading, error } = useQuery<Account[]>({
        queryKey: ['chart-of-accounts'],
        queryFn: async () => {
            const { data, error } = await supabase
                .from('accounts')
                .select('*')
                .order('code');
            if (error) throw error;
            return data as Account[];
        }
    });

    // Group accounts by type
    const groupedAccounts = useMemo(() => {
        if (!accounts) return {};
        const groups: Record<string, Account[]> = {};
        for (const acc of accounts) {
            const type = acc.account_type || 'Uncategorized';
            if (!groups[type]) groups[type] = [];
            groups[type].push(acc);
        }
        return groups;
    }, [accounts]);

    const [expandedGroups, setExpandedGroups] = useState<Record<string, boolean>>({});

    const toggleGroup = (type: string) => {
        setExpandedGroups(prev => ({ ...prev, [type]: !prev[type] }));
    };

    if (error) {
        return (
            <DashboardLayout>
                <div className="p-8">
                    <div className="bg-red-50 p-4 border border-red-200 rounded-lg">
                        <p className="text-red-700 font-bold">Error loading Chart of Accounts: {(error as Error).message}</p>
                    </div>
                </div>
            </DashboardLayout>
        );
    }

    return (
        <DashboardLayout>
            <div className="max-w-5xl mx-auto py-8 px-4">
                <div className="report-header mb-8 flex items-center justify-between">
                    <div>
                        <div className="flex items-center gap-3">
                            <div className="bg-slate-900 p-2 rounded-lg text-white">
                                <Landmark className="h-6 w-6" />
                            </div>
                            <div>
                                <h1 className="text-2xl font-black tracking-tight text-slate-900 uppercase">Chart of Accounts</h1>
                                <p className="text-slate-500 font-bold uppercase tracking-[0.2em] text-[10px]">Financial Account Hierarchy (View Only)</p>
                            </div>
                        </div>
                    </div>
                </div>

                {isLoading ? (
                    <div className="flex flex-col items-center justify-center min-h-[40vh] gap-4">
                        <Loader2 className="h-10 w-10 animate-spin text-slate-300" />
                        <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-400">Loading Accounts...</span>
                    </div>
                ) : (
                    <div className="space-y-4">
                        {Object.keys(groupedAccounts).sort().map(type => {
                            const isExpanded = expandedGroups[type] ?? true;
                            const typeAccounts = groupedAccounts[type];
                            return (
                                <Card key={type} className="overflow-hidden border border-slate-200 rounded-xl shadow-sm">
                                    <div
                                        className="bg-slate-50 px-6 py-4 flex items-center gap-3 cursor-pointer hover:bg-slate-100 transition-colors"
                                        onClick={() => toggleGroup(type)}
                                    >
                                        {isExpanded ? <ChevronDown className="h-5 w-5 text-slate-400" /> : <ChevronRight className="h-5 w-5 text-slate-400" />}
                                        <Folder className="h-5 w-5 text-blue-500" />
                                        <h2 className="font-black text-slate-800 uppercase tracking-widest text-sm">{type} <span className="text-slate-400 text-xs ml-2">({typeAccounts.length})</span></h2>
                                    </div>

                                    {isExpanded && (
                                        <div className="divide-y divide-slate-100 border-t border-slate-100 bg-white">
                                            {typeAccounts.map(acc => (
                                                <div key={acc.id} className="flex items-center px-8 py-3 hover:bg-slate-50 transition-colors group">
                                                    <div className="w-8 flex justify-center opacity-40 group-hover:opacity-100">
                                                        <FileText className="h-4 w-4 text-slate-400" />
                                                    </div>
                                                    <div className="flex-1">
                                                        <div className="flex items-center gap-2">
                                                            {acc.code && <span className="px-2 py-0.5 bg-slate-100 text-[10px] font-black uppercase tracking-widest text-slate-500 rounded border border-slate-200">{acc.code}</span>}
                                                            <span className="font-bold text-slate-700 uppercase text-xs">{acc.name}</span>
                                                        </div>
                                                    </div>
                                                    <div>
                                                        <span className={cn("text-[10px] font-black uppercase tracking-widest px-2 py-1 rounded", acc.is_active !== false ? "text-emerald-600 bg-emerald-50" : "text-rose-600 bg-rose-50")}>
                                                            {acc.is_active !== false ? "Active" : "Inactive"}
                                                        </span>
                                                    </div>
                                                </div>
                                            ))}
                                        </div>
                                    )}
                                </Card>
                            )
                        })}
                        {Object.keys(groupedAccounts).length === 0 && (
                            <div className="p-12 text-center text-slate-500 italic">No accounts found in the database.</div>
                        )}
                    </div>
                )}
            </div>
        </DashboardLayout>
    );
}
