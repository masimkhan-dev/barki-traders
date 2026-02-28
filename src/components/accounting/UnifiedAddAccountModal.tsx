import { useState, useEffect } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import {
    Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription, DialogFooter
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { toast } from 'sonner';
import { Loader2, Landmark, Wallet, Briefcase, Users, Receipt, Building, PlusCircle } from 'lucide-react';
import { cn } from '@/lib/utils';

interface UnifiedAddAccountModalProps {
    isOpen: boolean;
    onOpenChange: (open: boolean) => void;
    onSuccess?: (id: string, type: 'account' | 'party') => void;
    initialType?: AccountCategory;
    initialPartyType?: 'customer' | 'supplier' | 'both';
}

type AccountCategory = 'bank' | 'cash' | 'capital' | 'fixed_asset' | 'operating_expense' | 'utility_bill' | 'salary' | 'other_revenue' | 'loan' | 'trade_party';

export function UnifiedAddAccountModal({
    isOpen,
    onOpenChange,
    onSuccess,
    initialType,
    initialPartyType
}: UnifiedAddAccountModalProps) {
    const queryClient = useQueryClient();
    const [loading, setLoading] = useState(false);

    // Form State
    const [name, setName] = useState('');
    const [code, setCode] = useState('');
    const [type, setType] = useState<AccountCategory>(initialType || 'operating_expense');
    const [openingBalance, setOpeningBalance] = useState('0');
    const [partyType, setPartyType] = useState<'customer' | 'supplier' | 'both'>(initialPartyType || 'customer');

    // Sync initial state when modal opens
    useEffect(() => {
        if (isOpen) {
            if (initialType) setType(initialType);
            if (initialPartyType) setPartyType(initialPartyType);
        } else {
            resetForm();
        }
    }, [isOpen, initialType, initialPartyType]);

    const createMutation = useMutation({
        mutationFn: async () => {
            setLoading(true);

            try {
                // HANDLER FOR TRADE PARTIES
                if (type === 'trade_party') {
                    const { data, error } = await supabase
                        .from('parties')
                        .insert([{
                            name,
                            type: partyType,
                            opening_balance: parseFloat(openingBalance) || 0,
                            current_balance: parseFloat(openingBalance) || 0,
                            is_active: true
                        }])
                        .select()
                        .single();

                    if (error) throw error;

                    // Initialize Opening Balance via existing RPC
                    if (parseFloat(openingBalance) !== 0) {
                        await (supabase as any).rpc('initialize_party_opening_balance', {
                            p_party_id: data.id,
                            p_amount: parseFloat(openingBalance),
                            p_date: new Date().toISOString().split('T')[0]
                        });
                    }
                    return { success: true, table: 'parties', id: data.id };
                }

                // HANDLER FOR GENERAL ACCOUNTS
                else {
                    // Map selection to account_type
                    let accountType: 'asset' | 'liability' | 'equity' | 'income' | 'expense' = 'expense';
                    let codePrefix = '5'; // Default for expense

                    if (['bank', 'cash', 'fixed_asset'].includes(type)) {
                        accountType = 'asset';
                        codePrefix = '1';
                    }
                    if (['capital'].includes(type)) {
                        accountType = 'equity';
                        codePrefix = '3';
                    }
                    if (['loan'].includes(type)) {
                        accountType = 'liability';
                        codePrefix = '2';
                    }
                    if (['other_revenue'].includes(type)) {
                        accountType = 'income';
                        codePrefix = '4';
                    }

                    // ATOMIC: Use Secure RPC to ensure Trial Balance Integrity
                    const obAmount = parseFloat(openingBalance) || 0;

                    const { data, error } = await (supabase as any).rpc('create_secure_account_v1', {
                        p_name: name,
                        p_type: accountType,
                        p_sub_category: type,
                        p_opening_balance: obAmount
                    });

                    if (error) {
                        console.error("RPC Error:", error);
                        throw new Error(error.message || "Failed to execute secure account creation.");
                    }

                    const responseData = data as any;
                    return { success: true, table: 'accounts', id: responseData.account_id };
                }
            } finally {
                setLoading(false);
            }
        },
        onSuccess: (res) => {
            toast.success(`${res?.table === 'parties' ? 'Trade Party' : 'Account'} created successfully`);
            queryClient.invalidateQueries({ queryKey: ['unified-chart-of-accounts'] });
            queryClient.invalidateQueries({ queryKey: ['all-accounts-fresh'] });

            if (onSuccess && res?.id) {
                onSuccess(res.id, res.table === 'parties' ? 'party' : 'account');
            }

            onOpenChange(false);
            resetForm();
        },
        onError: (err: any) => {
            toast.error(err.message || "Failed to create account");
        }
    });

    const resetForm = () => {
        setName('');
        setCode('');
        setOpeningBalance('0');
        setType('operating_expense');
    };

    const currentCategoryDisplay = () => {
        if (['bank', 'cash', 'fixed_asset'].includes(type)) return 'ASSET';
        if (['capital'].includes(type)) return 'EQUITY';
        if (['loan'].includes(type)) return 'LIABILITY';
        if (['other_revenue'].includes(type)) return 'REVENUE';
        if (type === 'trade_party') return 'TRADE LEDGER (Net Balance)';
        return 'EXPENSE';
    };

    return (
        <Dialog open={isOpen} onOpenChange={onOpenChange}>
            <DialogContent className="sm:max-w-[500px] border-none shadow-2xl rounded-3xl p-0 overflow-hidden bg-white">
                <DialogHeader className="bg-slate-900 text-white p-8">
                    <div className="flex items-center gap-4 mb-2">
                        <div className="bg-white/10 p-2.5 rounded-xl backdrop-blur-sm border border-white/10">
                            <PlusCircle className="h-6 w-6 text-white" />
                        </div>
                        <div>
                            <DialogTitle className="text-xl font-black uppercase tracking-tight">Create New Account</DialogTitle>
                            <DialogDescription className="text-slate-400 font-bold uppercase text-[9px] tracking-[0.2em] mt-1">
                                Unified Financial Entry System
                            </DialogDescription>
                        </div>
                    </div>
                </DialogHeader>

                <div className="p-8 space-y-6">
                    {/* TYPE SELECTION */}
                    <div className="space-y-2">
                        <Label className="text-[10px] font-black uppercase tracking-widest text-slate-400">Account Type</Label>
                        <Select value={type} onValueChange={(v: AccountCategory) => setType(v)}>
                            <SelectTrigger className="h-12 rounded-xl border-slate-200 font-bold text-slate-700 bg-slate-50 focus:ring-slate-900 shadow-sm transition-all focus:border-slate-900">
                                <SelectValue placeholder="Select Account Type" />
                            </SelectTrigger>
                            <SelectContent className="rounded-xl border-slate-200 shadow-xl bg-white">
                                <SelectItem value="operating_expense" className="py-3 focus:bg-amber-50 rounded-lg cursor-pointer">
                                    <div className="flex items-center gap-2">
                                        <Receipt className="h-4 w-4 text-amber-500" />
                                        <span className="font-bold uppercase text-[10px]">Operating Expense</span>
                                    </div>
                                </SelectItem>
                                <SelectItem value="salary" className="py-3 focus:bg-amber-50 rounded-lg cursor-pointer">
                                    <div className="flex items-center gap-2">
                                        <Users className="h-4 w-4 text-amber-500" />
                                        <span className="font-bold uppercase text-[10px]">Staff Salaries</span>
                                    </div>
                                </SelectItem>
                                <SelectItem value="utility_bill" className="py-3 focus:bg-amber-50 rounded-lg cursor-pointer">
                                    <div className="flex items-center gap-2">
                                        <Building className="h-4 w-4 text-amber-500" />
                                        <span className="font-bold uppercase text-[10px]">Utility Bills</span>
                                    </div>
                                </SelectItem>
                                <SelectItem value="bank" className="py-3 focus:bg-emerald-50 rounded-lg cursor-pointer">
                                    <div className="flex items-center gap-2">
                                        <Landmark className="h-4 w-4 text-emerald-500" />
                                        <span className="font-bold uppercase text-[10px]">Bank Account</span>
                                    </div>
                                </SelectItem>
                                <SelectItem value="cash" className="py-3 focus:bg-emerald-50 rounded-lg cursor-pointer">
                                    <div className="flex items-center gap-2">
                                        <Wallet className="h-4 w-4 text-emerald-500" />
                                        <span className="font-bold uppercase text-[10px]">Physical Cash</span>
                                    </div>
                                </SelectItem>
                                <SelectItem value="capital" className="py-3 focus:bg-blue-50 rounded-lg cursor-pointer">
                                    <div className="flex items-center gap-2">
                                        <Briefcase className="h-4 w-4 text-blue-500" />
                                        <span className="font-bold uppercase text-[10px]">Owner's Capital</span>
                                    </div>
                                </SelectItem>
                                <SelectItem value="trade_party" className="py-3 focus:bg-indigo-50 rounded-lg cursor-pointer">
                                    <div className="flex items-center gap-2">
                                        <Users className="h-4 w-4 text-indigo-500" />
                                        <span className="font-bold uppercase text-[10px]">Trade Party (Cust/Supp)</span>
                                    </div>
                                </SelectItem>
                            </SelectContent>
                        </Select>
                        <div className="flex items-center gap-2 mt-1">
                            <span className="text-[9px] font-black uppercase text-slate-300">Category:</span>
                            <span className="text-[9px] font-black uppercase text-slate-900 underline decoration-slate-200 underline-offset-4 tracking-widest">{currentCategoryDisplay()}</span>
                        </div>
                    </div>

                    <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                        <div className="space-y-2">
                            <Label className="text-[10px] font-black uppercase tracking-widest text-slate-400">
                                {type === 'trade_party' ? 'Party Name' : 'Account Name'}
                            </Label>
                            <Input
                                value={name}
                                onChange={(e) => setName(e.target.value)}
                                placeholder={type === 'trade_party' ? "e.g. Ali Traders" : type === 'bank' ? "e.g. HBL Current" : "e.g. Electricity Bill"}
                                className="h-12 rounded-xl border-slate-200 font-bold text-slate-700 bg-white focus:ring-slate-900 focus:border-slate-900 shadow-sm"
                            />
                        </div>
                        <div className="space-y-2">
                            <Label className="text-[10px] font-black uppercase tracking-widest text-slate-400">Reference / Code</Label>
                            <Input
                                value={code}
                                onChange={(e) => setCode(e.target.value)}
                                placeholder="Optional"
                                className="h-12 rounded-xl border-slate-200 font-bold text-slate-700 bg-white focus:ring-slate-900 focus:border-slate-900 shadow-sm"
                            />
                        </div>
                    </div>

                    {type === 'trade_party' && (
                        <div className="space-y-3 animate-in fade-in slide-in-from-top-2 duration-300">
                            <Label className="text-[10px] font-black uppercase tracking-widest text-slate-400">Business Relationship</Label>
                            <div className="flex gap-2 p-1.5 bg-slate-100 rounded-2xl border border-slate-200">
                                {(['customer', 'supplier', 'both'] as const).map(t => (
                                    <Button
                                        key={t}
                                        type="button"
                                        variant={partyType === t ? 'default' : 'ghost'}
                                        onClick={() => setPartyType(t)}
                                        className={cn(
                                            "flex-1 h-10 rounded-xl font-black uppercase text-[10px] tracking-widest transition-all",
                                            partyType === t
                                                ? "bg-white text-slate-900 shadow-md border border-slate-200"
                                                : "bg-transparent text-slate-400 hover:text-slate-600 hover:bg-white/50"
                                        )}
                                    >
                                        {t}
                                    </Button>
                                ))}
                            </div>
                        </div>
                    )}

                    <div className="space-y-2">
                        <Label className="text-[10px] font-black uppercase tracking-widest text-slate-400">Opening Balance (Current Status)</Label>
                        <div className="relative group">
                            <Input
                                type="number"
                                value={openingBalance}
                                onChange={(e) => setOpeningBalance(e.target.value)}
                                className="h-14 rounded-xl border-slate-200 font-black text-slate-900 bg-slate-50 text-right text-xl pr-16 focus:ring-slate-900 focus:border-slate-900 shadow-inner group-hover:border-slate-400 transition-colors"
                            />
                            <span className="absolute right-5 top-1/2 -translate-y-1/2 text-[10px] font-black text-slate-400 pointer-events-none">PKR</span>
                        </div>
                    </div>
                </div>

                <DialogFooter className="bg-slate-50 p-8 flex flex-row items-center justify-between gap-6 border-t border-slate-200">
                    <Button
                        variant="ghost"
                        onClick={() => onOpenChange(false)}
                        className="font-black uppercase text-[10px] tracking-widest text-slate-400 hover:text-slate-900 hover:bg-white transition-all rounded-xl h-12 px-6"
                    >
                        Cancel
                    </Button>
                    <Button
                        onClick={() => createMutation.mutate()}
                        disabled={loading || !name}
                        className="flex-1 bg-slate-900 hover:bg-black text-white font-black uppercase text-[11px] tracking-widest h-14 rounded-2xl shadow-2xl shadow-slate-300 transition-all hover:-translate-y-0.5 active:translate-y-0 active:scale-95 disabled:opacity-30 flex items-center justify-center gap-3"
                    >
                        {loading ? (
                            <Loader2 className="h-5 w-5 animate-spin text-white" />
                        ) : (
                            <>
                                <PlusCircle className="h-5 w-5" />
                                <span>Commit to Ledger</span>
                            </>
                        )}
                    </Button>
                </DialogFooter>
            </DialogContent>
        </Dialog>
    );
}
