import { useState, useMemo } from 'react';
import { useQuery } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { supabase } from '@/integrations/supabase/client';
import { Loader2, Folder, FileText, ChevronDown, ChevronRight, Landmark, PlusCircle, Users } from 'lucide-react';
import { Card } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { cn } from '@/lib/utils';
import { UnifiedAddAccountModal } from '@/components/accounting/UnifiedAddAccountModal';

interface UnifiedAccount {
    id: string;
    name: string;
    code?: string;
    category: string; // Asset, Liability, Equity, Revenue, Expense
    sub_category: string; // Bank, Cash, Salary, etc.
    type: 'account' | 'party';
    is_active?: boolean;
}

export default function ChartOfAccounts() {
    const [expandedGroups, setExpandedGroups] = useState<Record<string, boolean>>({});
    const [isAddModalOpen, setIsAddModalOpen] = useState(false);

    const { data: accounts, isLoading, error } = useQuery<UnifiedAccount[]>({
        queryKey: ['unified-chart-of-accounts'],
        queryFn: async () => {
            const [accRes, partyRes] = await Promise.all([
                supabase.from('accounts').select('id, name, code, account_type, sub_category, is_active').order('code'),
                supabase.from('parties').select('id, name, type, is_active')
            ]);

            if (accRes.error) throw accRes.error;
            if (partyRes.error) throw partyRes.error;

            const generalAccounts: UnifiedAccount[] = (accRes.data as any[] || []).map(a => ({
                id: a.id,
                name: a.name,
                code: a.code,
                category: a.account_type,
                sub_category: a.sub_category || 'general',
                type: 'account',
                is_active: a.is_active
            }));

            const tradeParties: UnifiedAccount[] = partyRes.data.map(p => ({
                id: p.id,
                name: p.name,
                category: p.type === 'customer' ? 'asset' : (p.type === 'supplier' ? 'liability' : 'asset'), // Initial grouping
                sub_category: p.type === 'customer' ? 'trade_receivable' : (p.type === 'supplier' ? 'trade_payable' : 'trade_party'),
                type: 'party',
                is_active: p.is_active
            }));

            return [...generalAccounts, ...tradeParties];
        }
    });

    // 3-Level Grouping: Category -> Sub-Category -> Account
    const tableData = useMemo(() => {
        if (!accounts) return {};
        const hierarchy: any = {};

        // Define Category Order for consistent display
        const displayOrder = ['ASSET', 'LIABILITY', 'EQUITY', 'INCOME', 'EXPENSE'];

        accounts.forEach(acc => {
            const cat = acc.category.toUpperCase();
            const sub = acc.sub_category.replace(/_/g, ' ').toUpperCase();

            if (!hierarchy[cat]) hierarchy[cat] = {};
            if (!hierarchy[cat][sub]) hierarchy[cat][sub] = [];
            hierarchy[cat][sub].push(acc);
        });

        return hierarchy;
    }, [accounts]);

    const toggleGroup = (key: string) => {
        setExpandedGroups(prev => ({ ...prev, [key]: !prev[key] }));
    };

    if (error) {
        return (
            <DashboardLayout>
                <div className="p-8">
                    <div className="bg-red-50 p-6 border-2 border-red-200 rounded-none shadow-none">
                        <h3 className="text-red-800 font-black uppercase text-xs tracking-tighter mb-2">System Error</h3>
                        <p className="text-red-700 font-bold text-sm">Error loading Chart of Accounts: {(error as Error).message}</p>
                    </div>
                </div>
            </DashboardLayout>
        );
    }

    return (
        <DashboardLayout>
            <div className="max-w-6xl mx-auto py-10 px-6">
                {/* HEADER SECTION */}
                <div className="flex flex-col md:flex-row md:items-center justify-between gap-6 mb-10">
                    <div className="flex items-center gap-4">
                        <div className="bg-slate-900 p-3 rounded-none text-white shadow-none">
                            <Landmark className="h-6 w-6" />
                        </div>
                        <div>
                            <h1 className="text-3xl font-black tracking-tight text-slate-900 uppercase">Chart of Accounts</h1>
                            <p className="text-slate-400 font-bold uppercase tracking-[0.3em] text-[10px]">Unified Financial Tree & Ledger Hierarchy</p>
                        </div>
                    </div>

                    <Button
                        className="bg-slate-900 hover:bg-black text-white px-8 font-black uppercase text-[11px] tracking-widest gap-2 rounded-none shadow-none h-12 transition-none hover:scale-100 active:scale-100"
                        onClick={() => setIsAddModalOpen(true)}
                    >
                        <PlusCircle className="h-4 w-4" /> Add New Account
                    </Button>
                </div>

                {isLoading ? (
                    <div className="flex flex-col items-center justify-center min-h-[50vh] gap-6 bg-slate-50/50 rounded-none border-2 border-dashed border-slate-200">
                        <Loader2 className="h-12 w-12 animate-spin text-slate-200" />
                        <div className="text-center">
                            <span className="text-[11px] font-black uppercase tracking-[0.4em] text-slate-400 block">Synchronizing Ledger Data</span>
                            <span className="text-[9px] font-bold text-slate-300 uppercase tracking-widest mt-1 italic block">Optimizing group hierarchies...</span>
                        </div>
                    </div>
                ) : (
                    <div className="space-y-10">
                        {/* Iterate Categories */}
                        {['ASSET', 'LIABILITY', 'EQUITY', 'INCOME', 'EXPENSE'].filter(c => !!tableData[c]).map(category => (
                            <div key={category} className="space-y-4">
                                {/* CATEGORY HEADER */}
                                <div className="flex items-center gap-3 px-1">
                                    <div className={cn(
                                        "w-2.5 h-6 rounded-none",
                                        category === 'ASSET' ? "bg-emerald-500 shadow-none" :
                                            category === 'LIABILITY' ? "bg-rose-500 shadow-none" :
                                                category === 'EQUITY' ? "bg-blue-500 shadow-none" :
                                                    category === 'INCOME' ? "bg-indigo-500 shadow-none" :
                                                        "bg-amber-500 shadow-none"
                                    )} />
                                    <h2 className="font-black text-slate-900 uppercase tracking-[0.2em] text-sm py-1">
                                        {category}S <span className="text-slate-300 ml-2">/</span>
                                    </h2>
                                </div>

                                {/* SUB-CATEGORIES SECTION */}
                                <div className="grid gap-4">
                                    {Object.keys(tableData[category]).sort().map(sub => {
                                        const groupKey = `${category}-${sub}`;
                                        const isExpanded = expandedGroups[groupKey] ?? true;
                                        const items = tableData[category][sub];

                                        return (
                                            <Card key={sub} className="overflow-hidden border border-slate-300 rounded-none shadow-none hover:shadow-none transition-none">
                                                <div
                                                    className="bg-slate-50/80 px-7 py-4 flex items-center justify-between cursor-pointer hover:bg-slate-100/80 transition-none"
                                                    onClick={() => toggleGroup(groupKey)}
                                                >
                                                    <div className="flex items-center gap-4">
                                                        <div className="bg-white p-1.5 rounded-none border border-slate-200 shadow-none">
                                                            {isExpanded ? <ChevronDown className="h-4 w-4 text-slate-500" /> : <ChevronRight className="h-4 w-4 text-slate-500" />}
                                                        </div>
                                                        <Folder className={cn("h-4.5 w-4.5",
                                                            category === 'EXPENSE' ? "text-amber-500" :
                                                                category === 'ASSET' ? "text-emerald-500" :
                                                                    "text-blue-500"
                                                        )} />
                                                        <h3 className="font-black text-slate-700 uppercase tracking-widest text-[11px]">
                                                            {sub}
                                                            <span className="text-slate-400 text-[10px] font-bold ml-3 tracking-[0.1em]">[{items.length}]</span>
                                                        </h3>
                                                    </div>
                                                    <div className="h-1.5 w-1.5 rounded-none bg-slate-300" />
                                                </div>

                                                {isExpanded && (
                                                    <div className="divide-y divide-slate-50 bg-white">
                                                        {items.map((acc: UnifiedAccount) => (
                                                            <div key={acc.id} className="flex items-center px-10 py-4 hover:bg-slate-50/50 transition-none group border-l-4 border-transparent hover:border-slate-900/5">
                                                                <div className="w-10 flex justify-center opacity-60 group-hover:opacity-100 transition-none">
                                                                    {acc.type === 'party' ? <Users className="h-4 w-4 text-slate-900" /> : <FileText className="h-4 w-4 text-slate-900" />}
                                                                </div>
                                                                <div className="flex-1">
                                                                    <div className="flex items-center gap-3">
                                                                        {acc.code && <span className="px-2 py-0.5 bg-slate-100 text-[10px] font-black uppercase text-slate-500 rounded-none border border-slate-200 shadow-none">{acc.code}</span>}
                                                                        <span className="font-bold text-slate-800 uppercase text-[11px] tracking-tight transition-none">{acc.name}</span>
                                                                        {acc.type === 'party' && <span className="text-[10px] font-black uppercase text-indigo-600 bg-indigo-50 px-2 py-0.5 rounded-none border border-indigo-100 shadow-none ml-1">Trade Ledger</span>}
                                                                    </div>
                                                                </div>
                                                                <div>
                                                                    <div className={cn(
                                                                        "flex items-center gap-2 text-[10px] font-black uppercase tracking-widest px-3 py-1 rounded-none border-2 transition-none",
                                                                        acc.is_active !== false ? "text-emerald-700 bg-emerald-50 border-emerald-100 shadow-none" : "text-rose-700 bg-rose-50 border-rose-100 grayscale-[0.5]"
                                                                    )}>
                                                                        <div className={cn("w-1.5 h-1.5 rounded-none", acc.is_active !== false ? "bg-emerald-500" : "bg-rose-500")} />
                                                                        {acc.is_active !== false ? "Active" : "Archived"}
                                                                    </div>
                                                                </div>
                                                            </div>
                                                        ))}
                                                    </div>
                                                )}
                                            </Card>
                                        );
                                    })}
                                </div>
                            </div>
                        ))}
                    </div>
                )}

                {/* FOOTER INFO */}
                {!isLoading && (
                    <div className="mt-16 pt-8 border-t border-slate-100 flex flex-col md:flex-row items-center justify-between gap-4 opacity-70 transition-none">
                        <div className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">
                            © Fuel Trust Ledger System • Unified Accounting Structure v3.0
                        </div>
                        <div className="flex items-center gap-6">
                            <div className="flex items-center gap-2">
                                <FileText className="h-3 w-3" />
                                <span className="text-[9px] font-black uppercase tracking-widest italic">General Ledgers</span>
                            </div>
                            <div className="flex items-center gap-2">
                                <Users className="h-3 w-3" />
                                <span className="text-[9px] font-black uppercase tracking-widest italic">Trade Ledgers</span>
                            </div>
                        </div>
                    </div>
                )}
            </div>

            <UnifiedAddAccountModal
                isOpen={isAddModalOpen}
                onOpenChange={setIsAddModalOpen}
            />
        </DashboardLayout>
    );
}
