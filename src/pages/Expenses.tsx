
import { useState, useEffect } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
    Select,
    SelectContent,
    SelectItem,
    SelectTrigger,
    SelectValue,
} from '@/components/ui/select';
import { supabase } from '@/integrations/supabase/client';
import { useToast } from '@/hooks/use-toast';
import { formatPKR } from '@/lib/format';
import { Loader2, Receipt, Wallet, Banknote, History, CheckCircle2, AlertCircle } from 'lucide-react';

export default function Expenses() {
    const navigate = useNavigate();
    const [searchParams] = useSearchParams();
    const queryClient = useQueryClient();
    const { toast } = useToast();
    const [isEditMode, setIsEditMode] = useState(false);
    const [editVoucherNo, setEditVoucherNo] = useState<string | null>(null);
    const [form, setForm] = useState({
        date: new Date().toISOString().split('T')[0],
        expense_account_id: '',
        payment_account_id: '',
        amount: '',
        narration: '',
        asset_name: '',
        asset_category: 'Equipment'
    });

    useEffect(() => {
        const vNo = searchParams.get('edit');
        if (!vNo) return;

        const loadExpense = async () => {
            setIsEditMode(true);
            setEditVoucherNo(vNo);

            const { data: entries } = await supabase.from('ledger_entries').select('*').eq('voucher_no', vNo);
            if (entries && entries.length >= 2) {
                const debitEntry = entries.find(e => e.debit_amount > 0);
                const creditEntry = entries.find(e => e.credit_amount > 0);

                setForm({
                    date: debitEntry?.posting_date || new Date().toISOString().split('T')[0],
                    expense_account_id: debitEntry?.account_id || '',
                    payment_account_id: creditEntry?.account_id || '',
                    amount: String(Math.max(debitEntry?.debit_amount || 0, creditEntry?.credit_amount || 0)),
                    narration: debitEntry?.narration || '',
                    asset_name: '',
                    asset_category: 'Equipment'
                });
            }
        };
        loadExpense();
    }, [searchParams]);

    // 1. Fetch Expense Accounts
    const { data: expenseAccounts } = useQuery({
        queryKey: ['accounts-expense'],
        queryFn: async () => {
            const { data } = await supabase
                .from('accounts')
                .select('id, name, code')
                .eq('account_type', 'expense')
                .eq('is_active', true)
                .order('code');
            return data || [];
        },
        staleTime: 5 * 60 * 1000, // 5 minutes — expense categories rarely change
    });

    // 2. Fetch Payment Sources (Cash & Bank)
    const { data: paymentAccounts } = useQuery({
        queryKey: ['accounts-payment'],
        queryFn: async () => {
            const { data } = await supabase
                .from('accounts')
                .select('id, name, code')
                .eq('account_type', 'asset')
                .or('name.ilike.%cash%,name.ilike.%bank%')
                .eq('is_active', true);
            return data || [];
        },
        staleTime: 5 * 60 * 1000, // 5 minutes — payment sources rarely change
    });

    // 3. Fetch Recent Expenses
    const { data: recentExpenses } = useQuery({
        queryKey: ['recent-expenses', form.date],
        queryFn: async () => {
            const { data, error } = await supabase
                .from('ledger_entries')
                .select(`
                    id, 
                    voucher_no, 
                    debit_amount, 
                    narration, 
                    posting_date,
                    account:accounts(name)
                `)
                .eq('voucher_type', 'payment')
                .like('voucher_no', 'EXP-%')
                .order('created_at', { ascending: false })
                .limit(10);

            if (error) throw error;
            return data;
        }
    });

    const mutation = useMutation({
        mutationFn: async (payload: typeof form) => {
            if (!payload.payment_account_id || !payload.amount) {
                throw new Error("Please fill all required fields");
            }

            if (payload.expense_account_id === 'NEW_ASSET') {
                // BRANCH A: ASSET PURCHASE (Enterprise Flow)
                if (!payload.asset_name) throw new Error("Asset Name is required.");

                const { data, error } = await (supabase as any).rpc('purchase_fixed_asset', {
                    p_name: payload.asset_name,
                    p_category: payload.asset_category,
                    p_amount: parseFloat(payload.amount),
                    p_date: payload.date,
                    p_paid_from_account_id: payload.payment_account_id,
                    p_description: payload.narration
                });
                if (error) throw error;
                return data;

            } else if (payload.expense_account_id === 'OWNER_WITHDRAWAL') {
                // BRANCH C: OWNER PROFIT WITHDRAWAL
                const { data, error } = await (supabase as any).rpc('post_owner_withdrawal', {
                    p_payment_account_id: payload.payment_account_id,
                    p_amount: parseFloat(payload.amount),
                    p_narration: payload.narration || 'Owner Withdrawal',
                    p_date: payload.date
                });
                if (error) throw error;
                return data;

            } else {
                // BRANCH B: STANDARD EXPENSE (Normal Flow)
                if (!payload.expense_account_id) throw new Error("Expense Category is required.");

                const { data, error } = await (supabase as any).rpc('post_expense_entry', {
                    p_expense_account_id: payload.expense_account_id,
                    p_payment_account_id: payload.payment_account_id,
                    p_amount: parseFloat(payload.amount),
                    p_narration: payload.narration,
                    p_date: payload.date,
                    p_voucher_no: isEditMode ? editVoucherNo : null
                });
                if (error) throw error;
                return data;
            }
        },
        onSuccess: () => {
            toast({
                title: isEditMode ? 'Expense Revised' : 'Expense Recorded',
                description: isEditMode ? 'Original record replaced with new values.' : 'Transaction posted successfully to the ledger.'
            });
            setForm(prev => ({ ...prev, amount: '', narration: '' }));
            queryClient.invalidateQueries({ queryKey: ['roznamcha'] });
            queryClient.invalidateQueries({ queryKey: ['recent-expenses'] });
            queryClient.invalidateQueries({ queryKey: ['accounts-expense'] });
            queryClient.invalidateQueries({ queryKey: ['accounts-payment'] });
            if (isEditMode) {
                setIsEditMode(false);
                setEditVoucherNo(null);
                navigate('/expenses');
            }
        },
        onError: (e) => toast({ variant: 'destructive', title: 'Error', description: e.message })
    });

    return (

        <DashboardLayout>
            <div className="max-w-7xl mx-auto pb-20 px-6">

                <div className="report-header mb-8 flex justify-between items-end">
                    <div>
                        <h1 className="report-title">{isEditMode ? "Expense Revision" : "Expense Management"}</h1>
                        <p className="report-subtitle">
                            {isEditMode ? `Modifying original entry for ${editVoucherNo}.` : "Operating Expenditures & Administrative Cost Registry"}
                        </p>
                    </div>
                    {isEditMode && (
                        <Button
                            variant="destructive"
                            size="sm"
                            className="rounded-none font-black uppercase text-[10px] tracking-widest px-6"
                            onClick={() => {
                                setIsEditMode(false);
                                setEditVoucherNo(null);
                                setForm({
                                    date: new Date().toISOString().split('T')[0],
                                    expense_account_id: '',
                                    payment_account_id: '',
                                    amount: '',
                                    narration: '',
                                    asset_name: '',
                                    asset_category: 'Equipment'
                                });
                                navigate('/expenses');
                            }}
                        >
                            Abort Edit & Exit
                        </Button>
                    )}
                </div>

                <div className="grid grid-cols-1 lg:grid-cols-12 gap-8">
                    {/* INPUT FORM */}
                    <div className="lg:col-span-8">
                        <div className="border border-slate-300 bg-white">
                            <div className="bg-slate-900 px-6 py-3 flex items-center justify-between">
                                <h3 className="font-black text-white text-[10px] uppercase tracking-[0.2em] flex items-center gap-2">
                                    <Receipt className="h-3.5 w-3.5 text-slate-400" /> Expense Voucher Entry
                                </h3>
                                <div className="text-[9px] font-black bg-slate-800 px-3 py-1 text-slate-400 tracking-widest">POSTING: DOUBLE-ENTRY</div>
                            </div>

                            <div className="p-8">
                                <form onSubmit={(e) => { e.preventDefault(); mutation.mutate(form); }} className="space-y-8">
                                    <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
                                        <div className="space-y-2">
                                            <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">Transaction Date</Label>
                                            <Input type="date" value={form.date} onChange={e => setForm({ ...form, date: e.target.value })} className="h-11 rounded-none border-slate-300 font-bold" />
                                        </div>

                                        <div className="space-y-2">
                                            <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">Paid From (Source)</Label>
                                            <Select value={form.payment_account_id} onValueChange={(val) => setForm({ ...form, payment_account_id: val })}>
                                                <SelectTrigger className="h-11 rounded-none border-slate-300 font-bold focus:ring-0">
                                                    <SelectValue placeholder="Select Source (Cash/Bank)..." />
                                                </SelectTrigger>
                                                <SelectContent className="rounded-none border-slate-900">
                                                    {paymentAccounts?.map(a => <SelectItem key={a.id} value={a.id} className="font-bold text-xs uppercase">{a.name}</SelectItem>)}
                                                </SelectContent>
                                            </Select>
                                        </div>
                                    </div>

                                    <div className="p-6 bg-slate-50 border border-slate-200 space-y-8">
                                        <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
                                            <div className="space-y-2">
                                                <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">Expense Category / Asset Type</Label>
                                                <Select value={form.expense_account_id} onValueChange={(val) => setForm({ ...form, expense_account_id: val })}>
                                                    <SelectTrigger className="h-11 rounded-none border-slate-300 bg-white font-bold focus:ring-0">
                                                        <SelectValue placeholder="Classification..." />
                                                    </SelectTrigger>
                                                    <SelectContent className="rounded-none border-slate-900">
                                                        <SelectItem value="NEW_ASSET" className="font-black text-xs uppercase text-blue-600 bg-blue-50 border-b border-blue-100">
                                                            + RECORD NEW FIXED ASSET PURCHASE
                                                        </SelectItem>
                                                        <SelectItem value="OWNER_WITHDRAWAL" className="font-black text-xs uppercase text-amber-600 bg-amber-50 border-b border-amber-100">
                                                            ↑ OWNER PROFIT WITHDRAWAL
                                                        </SelectItem>
                                                        {expenseAccounts?.filter(a => a.code !== '5000').map(a => <SelectItem key={a.id} value={a.id} className="font-bold text-xs uppercase">{a.name}</SelectItem>)}
                                                    </SelectContent>
                                                </Select>
                                            </div>

                                            {form.expense_account_id === 'NEW_ASSET' ? (
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-blue-600 tracking-widest">Asset Name / Title</Label>
                                                    <Input
                                                        className="h-11 rounded-none border-blue-300 focus:border-blue-600 font-bold text-blue-900 bg-blue-50/50"
                                                        placeholder="e.g. Honda 125, Perkins Generator"
                                                        value={form.asset_name || ''}
                                                        onChange={e => setForm({ ...form, asset_name: e.target.value })}
                                                    />
                                                </div>
                                            ) : (
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">Amount (PKR)</Label>
                                                    <div className="relative">
                                                        <span className="absolute left-4 top-1/2 -translate-y-1/2 font-bold text-slate-400">Rs.</span>
                                                        <Input
                                                            className="h-11 rounded-none pl-12 text-xl font-black num-audit border-slate-300 focus:ring-0 focus:border-slate-900"
                                                            placeholder="0.00"
                                                            type="number"
                                                            value={form.amount}
                                                            onChange={e => setForm({ ...form, amount: e.target.value })}
                                                        />
                                                    </div>
                                                </div>
                                            )}
                                        </div>

                                        {form.expense_account_id === 'NEW_ASSET' && (
                                            <div className="grid grid-cols-1 md:grid-cols-2 gap-8 animate-in fade-in slide-in-from-top-2 duration-300">
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-blue-600 tracking-widest">Asset Category</Label>
                                                    <Select value={form.asset_category || 'Equipment'} onValueChange={(val) => setForm({ ...form, asset_category: val })}>
                                                        <SelectTrigger className="h-11 rounded-none border-blue-300 font-bold text-blue-900 bg-white">
                                                            <SelectValue />
                                                        </SelectTrigger>
                                                        <SelectContent>
                                                            <SelectItem value="Equipment">Equipment</SelectItem>
                                                            <SelectItem value="Vehicle">Vehicle</SelectItem>
                                                            <SelectItem value="Furniture">Furniture</SelectItem>
                                                            <SelectItem value="Machinery">Machinery</SelectItem>
                                                            <SelectItem value="Building">Building</SelectItem>
                                                        </SelectContent>
                                                    </Select>
                                                </div>
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-blue-600 tracking-widest">Purchase Cost (PKR)</Label>
                                                    <div className="relative">
                                                        <span className="absolute left-4 top-1/2 -translate-y-1/2 font-bold text-blue-400">Rs.</span>
                                                        <Input
                                                            className="h-11 rounded-none pl-12 text-xl font-black num-audit border-blue-300 focus:border-blue-600 focus:ring-0 text-blue-900"
                                                            placeholder="0.00"
                                                            type="number"
                                                            value={form.amount}
                                                            onChange={e => setForm({ ...form, amount: e.target.value })}
                                                        />
                                                    </div>
                                                </div>
                                            </div>
                                        )}

                                        <div className="space-y-2">
                                            <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">Narration / Internal Note</Label>
                                            <Input
                                                className="h-11 rounded-none bg-white font-bold border-slate-300 placeholder:font-medium placeholder:italic"
                                                placeholder={form.expense_account_id === 'NEW_ASSET' ? "Describe condition, warranty, vendor details..." : "e.g. Utility bill payment or maintenance labor cost"}
                                                value={form.narration}
                                                onChange={e => setForm({ ...form, narration: e.target.value })}
                                            />
                                        </div>
                                    </div>

                                    <Button type="submit" className={`h-12 w-full text-white font-black text-xs uppercase tracking-[0.2em] rounded-none shadow-sm transition-all ${form.expense_account_id === 'NEW_ASSET' ? 'bg-blue-600 hover:bg-blue-700' : form.expense_account_id === 'OWNER_WITHDRAWAL' ? 'bg-amber-600 hover:bg-amber-700' : 'bg-slate-900 hover:bg-black'}`} disabled={mutation.isPending}>
                                        {mutation.isPending ? <Loader2 className="animate-spin h-5 w-5 mr-2" /> : (form.expense_account_id === 'NEW_ASSET' ? <Wallet className="h-4 w-4 mr-2" /> : form.expense_account_id === 'OWNER_WITHDRAWAL' ? <Banknote className="h-4 w-4 mr-2" /> : <CheckCircle2 className="h-4 w-4 mr-2" />)}
                                        {mutation.isPending ? "PROCESSING..." : (form.expense_account_id === 'NEW_ASSET' ? "REGISTER ASSET & POST PAYMENT" : form.expense_account_id === 'OWNER_WITHDRAWAL' ? "POST OWNER WITHDRAWAL" : (isEditMode ? "REVISE EXPENSE VOUCHER" : "FINALIZE EXPENSE VOUCHER"))}
                                    </Button>
                                </form>
                            </div>
                        </div>
                    </div>

                    {/* SIDEBAR: RECENT HISTORY */}
                    <div className="lg:col-span-4 space-y-6">
                        <div className="border border-slate-300 bg-white overflow-hidden flex flex-col h-full max-h-[700px]">
                            <div className="px-6 py-3 bg-slate-100 border-b border-slate-200">
                                <h3 className="text-[10px] font-black uppercase text-slate-700 tracking-[0.2em] flex items-center gap-2">
                                    <History className="h-3.5 w-3.5" /> Recent Ledger
                                </h3>
                            </div>
                            <div className="flex-1 overflow-y-auto p-0">
                                {recentExpenses && recentExpenses.length > 0 ? (
                                    <div className="divide-y divide-slate-100">
                                        {recentExpenses.map((txn: any) => (
                                            <div key={txn.id} className="p-5 hover:bg-slate-50 transition-colors">
                                                <div className="flex justify-between items-start mb-2">
                                                    <span className="text-[9px] font-mono font-black text-slate-400 border border-slate-200 px-2 py-0.5 rounded-none">{txn.voucher_no}</span>
                                                    <span className="text-[9px] font-black text-slate-400 uppercase tracking-widest">{txn.posting_date}</span>
                                                </div>
                                                <div className="flex justify-between items-center">
                                                    <div>
                                                        <p className="text-[11px] font-black text-slate-800 uppercase leading-none mb-1">{txn.account?.name}</p>
                                                        <p className="text-[10px] text-slate-400 line-clamp-1 italic font-medium">{txn.narration}</p>
                                                    </div>
                                                    <span className="text-sm font-black text-liabilities num-audit">-{formatPKR(txn.debit_amount).replace('Rs. ', '')}</span>
                                                </div>
                                            </div>
                                        ))}
                                    </div>
                                ) : (
                                    <div className="p-12 text-center opacity-20">
                                        <AlertCircle className="h-10 w-10 text-slate-400 mx-auto mb-4" />
                                        <p className="text-[10px] font-black uppercase tracking-widest">No Recent Postings</p>
                                    </div>
                                )}
                            </div>
                        </div>

                        {/* AUDIT NOTE */}
                        <div className="border border-slate-900 p-6 bg-slate-900 text-white">
                            <h4 className="text-[11px] font-black uppercase tracking-widest mb-3 border-b border-white/20 pb-2">Internal Audit Note</h4>
                            <p className="text-[10px] text-slate-300 font-bold leading-relaxed uppercase tracking-tight">
                                Expense entries are immutable once recorded. All vouchers are cross-referenced with cash/bank balances in real-time. Unauthorized deletions are logged.
                            </p>
                        </div>
                    </div>
                </div>

            </div>
        </DashboardLayout>

    );
}
