
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
import { formatNumber, formatPKR } from '@/lib/format';
import { 
    Loader2, 
    Receipt, 
    Wallet, 
    Banknote, 
    History, 
    CheckCircle2, 
    AlertCircle, 
    PlusCircle,
    FlaskConical,
    ArrowRightLeft,
    AlertTriangle,
    Package,
    Calendar,
    PenTool,
    Users,
    Building,
    ArrowRight,
    TrendingDown,
    TrendingUp
} from 'lucide-react';
import { UnifiedAddAccountModal } from '@/components/accounting/UnifiedAddAccountModal';
import { cn } from '@/lib/utils';

type TransactionType = 'SALE' | 'PURCHASE' | 'EXPENSE' | 'ACTION_CENTER' | 'SHRINKAGE' | 'ASSET_PURCHASE' | 'OWNER_WITHDRAWAL';

interface EntityOption {
    id: string;
    name: string;
    type: 'party' | 'account';
    category?: string;
}

export default function ManageTransactions() {
    const navigate = useNavigate();
    const [searchParams] = useSearchParams();
    const queryClient = useQueryClient();
    const { toast } = useToast();
    
    const [txnType, setTxnType] = useState<TransactionType>('SALE');
    const [isEditMode, setIsEditMode] = useState(false);
    const [editVoucherNo, setEditVoucherNo] = useState<string | null>(null);
    const [isAddModalOpen, setIsAddModalOpen] = useState(false);

    const [form, setForm] = useState({
        date: new Date().toISOString().split('T')[0],
        expense_account_id: '',
        payment_account_id: '',
        amount: '',
        narration: '',
        // Asset specific
        asset_name: '',
        asset_category: 'Equipment',
        // Shrinkage specific
        fuel_type_id: '',
        quantity_lost: '',
        rate_per_liter: '',
        reason: 'Tanker Delivery Shortage',
        // Action Center specific
        from_entity_id: '',
        from_type: 'party' as 'party' | 'account',
        to_entity_id: '',
        to_type: 'account' as 'party' | 'account',
        action_type: 'transfer' as 'transfer' | 'receipt' | 'payment' | 'contra',
        // Sale/Purchase specific
        party_id: '',
        quantity: '',
        rate: '',
        is_credit: true,
        is_paid_now: false,
        payment_method: 'Cash'
    });

    const resetForm = () => {
        setForm({
            date: new Date().toISOString().split('T')[0],
            expense_account_id: '',
            payment_account_id: '',
            amount: '',
            narration: '',
            asset_name: '',
            asset_category: 'Equipment',
            fuel_type_id: '',
            quantity_lost: '',
            rate_per_liter: '',
            reason: 'Tanker Delivery Shortage',
            from_entity_id: '',
            from_type: 'party',
            to_entity_id: '',
            to_type: 'account',
            action_type: 'transfer',
            party_id: '',
            quantity: '',
            rate: '',
            is_credit: true,
            is_paid_now: false,
            payment_method: 'Cash'
        });
    };

    const handleTabChange = (type: TransactionType) => {
        if (isEditMode) {
            setIsEditMode(false);
            setEditVoucherNo(null);
            navigate('/manage-transactions');
        }
        setTxnType(type);
        resetForm();
    };

    // ── Load URL Params & Edit Mode ─────────────────────────────
    useEffect(() => {
        const vNo = searchParams.get('edit');
        const typeParam = searchParams.get('type');
        const fuelIdParam = searchParams.get('fuel_type_id');

        if (typeParam === 'SHRINKAGE') {
            setTxnType('SHRINKAGE');
            if (fuelIdParam) {
                setForm(prev => ({ ...prev, fuel_type_id: fuelIdParam }));
            }
        } else if (typeParam === 'SALE') {
            setTxnType('SALE');
        } else if (typeParam === 'PURCHASE') {
            setTxnType('PURCHASE');
        }

        if (!vNo) return;

        const loadTransaction = async () => {
            setIsEditMode(true);
            setEditVoucherNo(vNo);

            // 1. If it's a SALE
            if (vNo.startsWith('SAL-')) {
                setTxnType('SALE');
                const { data: sale } = await supabase
                    .from('sales')
                    .select('*')
                    .eq('voucher_no', vNo)
                    .single();
                
                if (sale) {
                    setForm(prev => ({
                        ...prev,
                        date: sale.sale_date,
                        party_id: sale.party_id,
                        fuel_type_id: sale.fuel_type_id,
                        quantity: String(sale.quantity),
                        rate: String(sale.rate_per_unit),
                        amount: String(sale.total_amount),
                        narration: sale.notes || '',
                        is_credit: sale.is_credit,
                        payment_method: 'Cash' // Default or fetch if available
                    }));
                }
                return;
            }

            // 2. If it's a PURCHASE
            if (vNo.startsWith('PUR-')) {
                setTxnType('PURCHASE');
                const { data: purchase } = await supabase
                    .from('purchases')
                    .select('*')
                    .eq('voucher_no', vNo)
                    .single();
                
                if (purchase) {
                    setForm(prev => ({
                        ...prev,
                        date: purchase.purchase_date,
                        party_id: purchase.party_id,
                        fuel_type_id: purchase.fuel_type_id,
                        quantity: String(purchase.quantity),
                        rate: String(purchase.rate_per_unit),
                        amount: String(purchase.total_amount),
                        narration: purchase.notes || '',
                        is_paid_now: purchase.is_paid_now,
                        payment_method: purchase.payment_method || 'Cash'
                    }));
                }
                return;
            }

            // 3. If it's a SHRINKAGE
            if (vNo.startsWith('SHR-')) {
                setTxnType('SHRINKAGE');
                const { data: entries } = await supabase
                    .from('ledger_entries')
                    .select('*')
                    .eq('voucher_no', vNo);
                
                if (entries && entries.length > 0) {
                    const first = entries[0];
                    // Shrinkage details are often in narration or we might need a specific table
                    // For now, let's parse from narration or assume common values
                    setForm(prev => ({
                        ...prev,
                        date: first.posting_date,
                        amount: String(first.debit_amount || first.credit_amount),
                        narration: first.narration || '',
                    }));
                }
                return;
            }

            // 4. Generic Ledger (EXPENSE / ACTION_CENTER)
            const { data: entries } = await supabase.from('ledger_entries').select('*').eq('voucher_no', vNo);
            if (entries && entries.length >= 2) {
                // In accounting, Credit is Source (From), Debit is Target (To)
                const creditEntry = entries.find(e => e.credit_amount > 0);
                const debitEntry = entries.find(e => e.debit_amount > 0);

                if (vNo.startsWith('EXP-')) {
                    setTxnType('EXPENSE');
                    setForm(prev => ({
                        ...prev,
                        date: debitEntry?.posting_date || new Date().toISOString().split('T')[0],
                        expense_account_id: debitEntry?.account_id || '',
                        payment_account_id: creditEntry?.account_id || '',
                        amount: String(creditEntry?.credit_amount || 0),
                        narration: debitEntry?.narration || '',
                    }));
                } else {
                    setTxnType('ACTION_CENTER');
                    setForm(prev => ({
                        ...prev,
                        date: debitEntry?.posting_date || new Date().toISOString().split('T')[0],
                        amount: String(debitEntry?.debit_amount || 0),
                        narration: debitEntry?.narration || '',
                        // Source (From)
                        from_type: creditEntry?.party_id ? 'party' : 'account',
                        from_entity_id: creditEntry?.party_id || creditEntry?.account_id || '',
                        // Target (To)
                        to_type: debitEntry?.party_id ? 'party' : 'account',
                        to_entity_id: debitEntry?.party_id || debitEntry?.account_id || '',
                        // Determine action type for backend compatibility
                        action_type: creditEntry?.party_id && debitEntry?.party_id ? 'transfer' :
                                    creditEntry?.party_id ? 'receipt' :
                                    debitEntry?.party_id ? 'payment' : 'contra'
                    }));
                }
            }
        };
        loadTransaction();
    }, [searchParams]);

    // ── Data Fetching ───────────────────────────────────────────
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
    });

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
    });

    const { data: allAccounts } = useQuery({
        queryKey: ['accounts-all-active'],
        queryFn: async () => {
            const { data } = await supabase
                .from('accounts')
                .select('id, name, code, account_type')
                .eq('is_active', true)
                .order('name');
            return data || [];
        }
    });

    const { data: parties } = useQuery({
        queryKey: ['parties-active'],
        queryFn: async () => {
            const { data } = await supabase
                .from('parties')
                .select('id, name, type')
                .eq('is_active', true)
                .order('name');
            return data || [];
        }
    });

    const { data: fuelTypes } = useQuery({
        queryKey: ['fuel-types-active'],
        queryFn: async () => {
            const { data } = await supabase
                .from('fuel_types')
                .select('id, name, unit')
                .eq('is_active', true)
                .order('name');
            return data || [];
        }
    });

    const { data: recentVouchers } = useQuery({
        queryKey: ['recent-factory-vouchers'],
        queryFn: async () => {
            const { data, error } = await supabase
                .from('ledger_entries')
                .select(`
                    voucher_no,
                    voucher_type,
                    posting_date,
                    narration,
                    debit_amount,
                    credit_amount,
                    accounts(name),
                    party:parties(name)
                `)
                .in('voucher_type', ['sale', 'purchase', 'adjustment', 'receipt', 'payment', 'opening'] as any[])
                .order('created_at', { ascending: false })
                .limit(15);

            if (error) throw error;
            
            // Unique by voucher_no
            const unique = [];
            const seen = new Set();
            for (const item of data) {
                if (!seen.has(item.voucher_no)) {
                    unique.push(item);
                    seen.add(item.voucher_no);
                }
            }
            return unique;
        }
    });

    // ── Mutation ───────────────────────────────────────────────
    const mutation = useMutation({
        mutationFn: async (payload: typeof form) => {
            if (txnType === 'SALE') {
                if (!payload.party_id || !payload.fuel_type_id || !payload.quantity || !payload.rate) {
                    throw new Error("Customer, Fuel Type, Quantity, and Rate are required.");
                }
                
                const { data: vNo } = await supabase.rpc('generate_voucher_no', { prefix: 'SAL' });
                const qty = parseFloat(payload.quantity);
                const rate = parseFloat(payload.rate);
                const total = qty * rate;

                const { data, error } = await supabase.from('sales').insert({
                    voucher_no: vNo,
                    sale_date: payload.date,
                    party_id: payload.party_id,
                    fuel_type_id: payload.fuel_type_id,
                    quantity: qty,
                    rate_per_unit: rate,
                    total_amount: total,
                    is_credit: payload.is_credit,
                    notes: payload.narration
                }).select().single();
                
                if (error) throw error;
                return data;
            }

            if (txnType === 'PURCHASE') {
                if (!payload.party_id || !payload.fuel_type_id || !payload.quantity || !payload.rate) {
                    throw new Error("Supplier, Fuel Type, Quantity, and Rate are required.");
                }

                const { data: vNo } = await supabase.rpc('generate_voucher_no', { prefix: 'PUR' });
                const qty = parseFloat(payload.quantity);
                const rate = parseFloat(payload.rate);
                const total = qty * rate;

                const { data, error } = await supabase.from('purchases').insert({
                    voucher_no: vNo,
                    purchase_date: payload.date,
                    party_id: payload.party_id,
                    fuel_type_id: payload.fuel_type_id,
                    quantity: qty,
                    rate_per_unit: rate,
                    total_amount: total,
                    is_paid_now: payload.is_paid_now,
                    payment_method: payload.payment_method,
                    notes: payload.narration
                }).select().single();

                if (error) throw error;
                return data;
            }

            if (txnType === 'ACTION_CENTER') {
                if (!payload.from_entity_id || !payload.to_entity_id || !payload.amount) {
                    throw new Error("Source, Destination, and Amount are required.");
                }
                if (payload.from_entity_id === payload.to_entity_id && payload.from_type === payload.to_type) {
                    throw new Error("Source and Destination cannot be the same.");
                }
                const { data, error } = await (supabase as any).rpc('create_manage_transaction', {
                    p_transaction_type: payload.action_type,
                    p_from_type: payload.from_type,
                    p_from_entity_id: payload.from_entity_id,
                    p_to_type: payload.to_type,
                    p_to_entity_id: payload.to_entity_id,
                    p_amount: parseFloat(payload.amount),
                    p_narration: payload.narration,
                    p_transaction_date: payload.date
                });
                if (error) throw error;
                return data;
            }

            if (txnType === 'SHRINKAGE') {
                if (!payload.fuel_type_id || !payload.quantity_lost || !payload.rate_per_liter) {
                    throw new Error("Please provide Fuel Type, Quantity and Rate.");
                }
                const { data, error } = await (supabase as any).rpc('post_fuel_shrinkage_writeoff', {
                    p_fuel_type_id: payload.fuel_type_id,
                    p_quantity_lost: parseFloat(payload.quantity_lost),
                    p_rate_per_liter: parseFloat(payload.rate_per_liter),
                    p_date: payload.date,
                    p_reason: payload.reason,
                    p_voucher_no: isEditMode ? editVoucherNo : null
                });
                if (error) throw error;
                return data;
            }

            if (txnType === 'EXPENSE') {
                if (!payload.expense_account_id || !payload.payment_account_id || !payload.amount) {
                    throw new Error("Missing required fields.");
                }
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

            if (txnType === 'ASSET_PURCHASE') {
                if (!payload.asset_name || !payload.amount || !payload.payment_account_id) {
                    throw new Error("Missing asset details or payment source.");
                }
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
            }

            if (txnType === 'OWNER_WITHDRAWAL') {
                if (!payload.amount || !payload.payment_account_id) {
                    throw new Error("Amount and payment source required.");
                }
                const { data, error } = await (supabase as any).rpc('post_owner_withdrawal', {
                    p_payment_account_id: payload.payment_account_id,
                    p_amount: parseFloat(payload.amount),
                    p_narration: payload.narration || 'Owner Withdrawal',
                    p_date: payload.date
                });
                if (error) throw error;
                return data;
            }
        },
        onSuccess: () => {
            toast({
                title: 'Transaction Posted',
                description: 'The record has been committed to the ledger and inventory.'
            });
            // Reset form partly
            resetForm();
            queryClient.invalidateQueries({ queryKey: ['roznamcha'] });
            queryClient.invalidateQueries({ queryKey: ['recent-factory-vouchers'] });
            queryClient.invalidateQueries({ queryKey: ['calculated-inventory'] });
            
            if (isEditMode) {
                setIsEditMode(false);
                setEditVoucherNo(null);
                navigate('/manage-transactions');
            }
        },
        onError: (e) => toast({ variant: 'destructive', title: 'Transaction Failed', description: e.message })
    });

    const handleTypeChange = (val: TransactionType) => {
        setTxnType(val);
        // Reset some fields that are specific
        setForm(prev => ({
            ...prev,
            amount: '',
            narration: '',
            expense_account_id: '',
            fuel_type_id: '',
            quantity_lost: '',
            rate_per_liter: '',
            party_id: '',
            quantity: '',
            rate: ''
        }));
    };

    return (
        <DashboardLayout>
            <div className="max-w-7xl mx-auto pb-20 px-6">
                <div className="report-header mb-8 flex justify-between items-end">
                    <div>
                        <h1 className="report-title">{isEditMode ? "Modify Transaction" : "Voucher Factory"}</h1>
                        <p className="report-subtitle">
                            {isEditMode 
                                ? `Revising existing voucher ${editVoucherNo}` 
                                : "Unified terminal for processing administrative, operational, and inventory adjustments."}
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
                                navigate('/manage-transactions');
                            }}
                        >
                            Cancel Edit
                        </Button>
                    )}
                </div>

                <div className="grid grid-cols-1 lg:grid-cols-12 gap-8">
                    {/* ── LEFT: MAIN FORM ──────────────────────────────── */}
                    <div className="lg:col-span-8">
                        <div className="border border-slate-300 bg-white">
                            <div className="bg-slate-900 px-6 py-6 border-b border-slate-800">
                                <div className="flex flex-wrap gap-2">
                                    {[
                                        { id: 'SALE', label: 'Fuel Sale', icon: TrendingUp, color: 'emerald' },
                                        { id: 'PURCHASE', label: 'Fuel Purchase', icon: TrendingDown, color: 'rose' },
                                        { id: 'ACTION_CENTER', label: 'Party Transfer', icon: Users, color: 'emerald' },
                                        { id: 'EXPENSE', label: 'Standard Expense', icon: Wallet, color: 'slate' },
                                        { id: 'SHRINKAGE', label: 'Fuel Loss', icon: AlertTriangle, color: 'rose' },
                                        { id: 'ASSET_PURCHASE', label: 'Asset Entry', icon: Building, color: 'blue' },
                                        { id: 'OWNER_WITHDRAWAL', label: 'Owner Out', icon: History, color: 'amber' },
                                    ].map((mode) => (
                                        <button
                                            key={mode.id}
                                            type="button"
                                            onClick={() => handleTabChange(mode.id as TransactionType)}
                                            className={cn(
                                                "flex items-center gap-3 px-4 py-2 text-[10px] font-black uppercase tracking-widest border transition-all",
                                                txnType === mode.id 
                                                    ? `bg-${mode.color}-600 border-${mode.color}-500 text-white shadow-[0_0_15px_rgba(0,0,0,0.3)]`
                                                    : "bg-slate-800 border-slate-700 text-slate-400 hover:text-white hover:border-slate-500"
                                            )}
                                        >
                                            <mode.icon className={cn("h-4 w-4", txnType === mode.id ? "text-white" : "text-slate-500")} />
                                            {mode.label}
                                        </button>
                                    ))}
                                </div>
                            </div>

                            <div className="p-8">
                                <form onSubmit={(e) => { e.preventDefault(); mutation.mutate(form); }} className="space-y-8">
                                    
                                    {/* ── SHARED: DATE & SOURCE ────────────────────────── */}
                                    <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
                                        <div className="space-y-2">
                                            <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest flex items-center gap-2">
                                                <Calendar className="h-3 w-3" /> Posting Date
                                            </Label>
                                            <Input 
                                                type="date" 
                                                value={form.date} 
                                                onChange={e => setForm({ ...form, date: e.target.value })} 
                                                className="h-11 rounded-none border-slate-300 font-bold" 
                                            />
                                        </div>

                                        {txnType !== 'SHRINKAGE' && txnType !== 'ACTION_CENTER' && txnType !== 'SALE' && txnType !== 'PURCHASE' && (
                                            <div className="space-y-2">
                                                <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest flex items-center gap-2">
                                                    <Wallet className="h-3 w-3" /> Payment Source (Cash/Bank)
                                                </Label>
                                                <Select value={form.payment_account_id} onValueChange={(val) => setForm({ ...form, payment_account_id: val })}>
                                                    <SelectTrigger className="h-11 rounded-none border-slate-300 font-bold focus:ring-0">
                                                        <SelectValue placeholder="Select Cash/Bank..." />
                                                    </SelectTrigger>
                                                    <SelectContent className="rounded-none border-slate-900">
                                                        {paymentAccounts?.map(a => <SelectItem key={a.id} value={a.id} className="font-bold text-xs uppercase">{a.name}</SelectItem>)}
                                                    </SelectContent>
                                                </Select>
                                            </div>
                                        )}
                                        {(txnType === 'SALE' || txnType === 'PURCHASE') && (
                                            <div className="space-y-2">
                                                <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest flex items-center gap-2">
                                                    <Users className="h-3 w-3" /> {txnType === 'SALE' ? 'Select Customer' : 'Select Supplier'}
                                                </Label>
                                                <Select value={form.party_id} onValueChange={(val) => setForm({ ...form, party_id: val })}>
                                                    <SelectTrigger className="h-11 rounded-none border-slate-300 font-bold focus:ring-0">
                                                        <SelectValue placeholder={`Search ${txnType === 'SALE' ? 'Customer' : 'Supplier'}...`} />
                                                    </SelectTrigger>
                                                    <SelectContent className="rounded-none border-slate-900 max-h-[300px]">
                                                        {parties?.map(p => (
                                                            <SelectItem key={p.id} value={p.id} className="font-bold text-xs uppercase">{p.name}</SelectItem>
                                                        ))}
                                                    </SelectContent>
                                                </Select>
                                            </div>
                                        )}
                                        {txnType === 'ACTION_CENTER' && (
                                            <div className="space-y-2">
                                                <Label className="text-[10px] uppercase font-black text-emerald-600 tracking-widest flex items-center gap-2">
                                                    <ArrowRightLeft className="h-3 w-3" /> Movement Terminal
                                                </Label>
                                                <div className="h-11 px-4 flex items-center bg-emerald-600 border border-emerald-700 text-white font-black text-xs uppercase tracking-tighter">
                                                    Simplified Transfer: Party | Cash | Bank
                                                </div>
                                            </div>
                                        )}
                                    </div>

                                    {/* ── TYPE SPECIFIC CONTENT ────────────────────────── */}
                                    <div className={cn(
                                        "p-6 border space-y-8 transition-all",
                                        txnType === 'ACTION_CENTER' ? "bg-emerald-50 border-emerald-100" :
                                        txnType === 'SHRINKAGE' ? "bg-rose-50 border-rose-100" : 
                                        txnType === 'ASSET_PURCHASE' ? "bg-blue-50 border-blue-100" :
                                        txnType === 'OWNER_WITHDRAWAL' ? "bg-amber-50 border-amber-100" :
                                        "bg-slate-50 border-slate-200"
                                    )}>

                                        {/* 0. SALE & PURCHASE FLOW */}
                                        {(txnType === 'SALE' || txnType === 'PURCHASE') && (
                                            <div className="space-y-8">
                                                <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">Fuel Type</Label>
                                                        <Select value={form.fuel_type_id} onValueChange={(val) => setForm({ ...form, fuel_type_id: val })}>
                                                            <SelectTrigger className="h-11 rounded-none border-slate-300 bg-white font-bold focus:ring-0">
                                                                <SelectValue placeholder="Select Fuel..." />
                                                            </SelectTrigger>
                                                            <SelectContent className="rounded-none border-slate-900">
                                                                {fuelTypes?.map(f => <SelectItem key={f.id} value={f.id} className="font-bold text-xs uppercase">{f.name}</SelectItem>)}
                                                            </SelectContent>
                                                        </Select>
                                                    </div>
                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">Quantity ({fuelTypes?.find(f => f.id === form.fuel_type_id)?.unit || 'Ltrs'})</Label>
                                                        <Input
                                                            className="h-11 rounded-none text-xl font-black num-audit border-slate-300 bg-white focus:ring-0"
                                                            placeholder="0.00"
                                                            type="number"
                                                            value={form.quantity}
                                                            onChange={e => setForm({ ...form, quantity: e.target.value })}
                                                        />
                                                    </div>
                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">Rate per Unit</Label>
                                                        <div className="relative">
                                                            <span className="absolute left-4 top-1/2 -translate-y-1/2 font-bold text-slate-400 text-xs">Rs.</span>
                                                            <Input
                                                                className="h-11 rounded-none pl-10 text-xl font-black num-audit border-slate-300 bg-white focus:ring-0"
                                                                placeholder="0.00"
                                                                type="number"
                                                                value={form.rate}
                                                                onChange={e => setForm({ ...form, rate: e.target.value })}
                                                            />
                                                        </div>
                                                    </div>
                                                </div>

                                                <div className="flex flex-wrap items-center justify-between gap-4 p-4 bg-white border border-slate-200">
                                                    <div className="flex flex-col">
                                                        <span className="text-[10px] font-black uppercase text-slate-400">Estimated Total</span>
                                                        <span className="text-2xl font-black text-slate-900 num-audit">
                                                            {formatPKR(parseFloat(form.quantity || '0') * parseFloat(form.rate || '0'))}
                                                        </span>
                                                    </div>
                                                    
                                                    {/* Forced to Credit (Udhaar) - Toggle removed per user request */}
                                                </div>
                                            </div>
                                        )}

                                        {/* 0. ACTION CENTER (SIMPLIFIED TRANSFERS) */}
                                        {txnType === 'ACTION_CENTER' && (
                                            <div className="space-y-8">
                                                <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
                                                    <div className="space-y-2 md:col-span-2">
                                                        <Label className="text-[10px] uppercase font-black text-emerald-600 tracking-widest">Amount to Move (PKR)</Label>
                                                        <div className="relative">
                                                            <span className="absolute left-4 top-1/2 -translate-y-1/2 font-black text-emerald-400 text-lg">Rs.</span>
                                                            <Input
                                                                className="h-14 rounded-none pl-12 text-3xl font-black num-audit border-emerald-300 bg-white text-emerald-900 focus:ring-0 shadow-sm"
                                                                placeholder="0.00"
                                                                type="number"
                                                                value={form.amount}
                                                                onChange={e => setForm({ ...form, amount: e.target.value })}
                                                            />
                                                        </div>
                                                    </div>
                                                </div>

                                                <div className="grid grid-cols-1 md:grid-cols-2 gap-12 pt-4">
                                                    {/* FROM ENTITY */}
                                                    <div className="space-y-4">
                                                        <div className="flex justify-between items-center border-b border-emerald-200 pb-2">
                                                            <div className="flex items-center gap-2">
                                                                <TrendingDown className="h-3 w-3 text-rose-500" />
                                                                <Label className="text-[10px] uppercase font-black text-emerald-600 tracking-widest">SENDER (Paisa Nikla)</Label>
                                                            </div>
                                                        </div>
                                                        <Select 
                                                            value={form.from_entity_id} 
                                                            onValueChange={(val) => {
                                                                const isParty = parties?.some(p => p.id === val);
                                                                setForm({ ...form, from_entity_id: val, from_type: isParty ? 'party' : 'account' });
                                                            }}
                                                        >
                                                            <SelectTrigger className="h-12 rounded-none border-emerald-300 bg-white font-black text-xs uppercase text-emerald-900 shadow-sm">
                                                                <SelectValue placeholder="Select Sender (Who paid?)" />
                                                            </SelectTrigger>
                                                            <SelectContent className="max-h-[300px] rounded-none border-emerald-900">
                                                                <div className="p-2 bg-slate-100 text-[9px] font-bold text-slate-500 uppercase tracking-widest">Parties / Customers / Suppliers</div>
                                                                {parties?.map(p => <SelectItem key={p.id} value={p.id} className="font-bold text-xs uppercase py-3 border-b border-slate-50 last:border-0"><Users className="h-3 w-3 inline mr-2 text-slate-400" /> {p.name}</SelectItem>)}
                                                                <div className="p-2 bg-slate-100 text-[9px] font-bold text-slate-500 uppercase tracking-widest">Cash / Bank / Assets</div>
                                                                {allAccounts?.filter(a => a.account_type === 'asset' || a.account_type === 'bank' || a.account_type === 'cash').map(a => (
                                                                    <SelectItem key={a.id} value={a.id} className="font-bold text-xs uppercase py-3 border-b border-slate-50 last:border-0"><Building className="h-3 w-3 inline mr-2 text-slate-400" /> {a.name}</SelectItem>
                                                                ))}
                                                            </SelectContent>
                                                        </Select>
                                                    </div>

                                                    {/* TO ENTITY */}
                                                    <div className="space-y-4">
                                                        <div className="flex justify-between items-center border-b border-emerald-200 pb-2">
                                                            <div className="flex items-center gap-2">
                                                                <TrendingUp className="h-3 w-3 text-emerald-500" />
                                                                <Label className="text-[10px] uppercase font-black text-emerald-600 tracking-widest">RECEIVER (Paisa Aya)</Label>
                                                            </div>
                                                        </div>
                                                        <Select 
                                                            value={form.to_entity_id} 
                                                            onValueChange={(val) => {
                                                                const isParty = parties?.some(p => p.id === val);
                                                                setForm({ ...form, to_entity_id: val, to_type: isParty ? 'party' : 'account' });
                                                            }}
                                                        >
                                                            <SelectTrigger className="h-12 rounded-none border-emerald-300 bg-white font-black text-xs uppercase text-emerald-900 shadow-sm">
                                                                <SelectValue placeholder="Select Receiver (Who got paid?)" />
                                                            </SelectTrigger>
                                                            <SelectContent className="max-h-[300px] rounded-none border-emerald-900">
                                                                <div className="p-2 bg-slate-100 text-[9px] font-bold text-slate-500 uppercase tracking-widest">Parties / Customers / Suppliers</div>
                                                                {parties?.map(p => <SelectItem key={p.id} value={p.id} className="font-bold text-xs uppercase py-3 border-b border-slate-50 last:border-0"><Users className="h-3 w-3 inline mr-2 text-slate-400" /> {p.name}</SelectItem>)}
                                                                <div className="p-2 bg-slate-100 text-[9px] font-bold text-slate-500 uppercase tracking-widest">Cash / Bank / Assets</div>
                                                                {allAccounts?.filter(a => a.account_type === 'asset' || a.account_type === 'bank' || a.account_type === 'cash').map(a => (
                                                                    <SelectItem key={a.id} value={a.id} className="font-bold text-xs uppercase py-3 border-b border-slate-50 last:border-0"><Building className="h-3 w-3 inline mr-2 text-slate-400" /> {a.name}</SelectItem>
                                                                ))}
                                                            </SelectContent>
                                                        </Select>
                                                    </div>
                                                </div>
                                            </div>
                                        )}

                                        {/* 1. EXPENSE FLOW */}
                                        {txnType === 'EXPENSE' && (
                                            <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
                                                <div className="space-y-2">
                                                    <div className="flex justify-between items-center">
                                                        <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">Expense Classification</Label>
                                                        <button 
                                                            type="button"
                                                            onClick={() => setIsAddModalOpen(true)}
                                                            className="text-[9px] font-black text-slate-400 hover:text-slate-900 flex items-center gap-1 uppercase"
                                                        >
                                                            <PlusCircle className="h-2.5 w-2.5" /> Add New
                                                        </button>
                                                    </div>
                                                    <Select value={form.expense_account_id} onValueChange={(val) => setForm({ ...form, expense_account_id: val })}>
                                                        <SelectTrigger className="h-11 rounded-none border-slate-300 bg-white font-bold focus:ring-0">
                                                            <SelectValue placeholder="Select Category..." />
                                                        </SelectTrigger>
                                                        <SelectContent className="rounded-none border-slate-900">
                                                            {expenseAccounts?.map(a => <SelectItem key={a.id} value={a.id} className="font-bold text-xs uppercase">{a.name}</SelectItem>)}
                                                        </SelectContent>
                                                    </Select>
                                                </div>
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
                                            </div>
                                        )}

                                        {/* 2. SHRINKAGE FLOW */}
                                        {txnType === 'SHRINKAGE' && (
                                            <>
                                                <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-rose-600 tracking-widest">Select Product</Label>
                                                        <Select value={form.fuel_type_id} onValueChange={(val) => setForm({ ...form, fuel_type_id: val })}>
                                                            <SelectTrigger className="h-11 rounded-none border-rose-300 bg-white font-bold text-rose-900 focus:ring-0">
                                                                <SelectValue placeholder="Fuel Type..." />
                                                            </SelectTrigger>
                                                            <SelectContent className="rounded-none border-slate-900">
                                                                {fuelTypes?.map(f => <SelectItem key={f.id} value={f.id} className="font-bold text-xs uppercase">{f.name}</SelectItem>)}
                                                            </SelectContent>
                                                        </Select>
                                                    </div>
                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-rose-600 tracking-widest">Qty Lost (Liters)</Label>
                                                        <div className="relative">
                                                            <Input
                                                                className="h-11 rounded-none pr-12 text-xl font-black num-audit border-rose-300 bg-white text-rose-900 focus:ring-0"
                                                                placeholder="0.00"
                                                                type="number"
                                                                value={form.quantity_lost}
                                                                onChange={e => setForm({ ...form, quantity_lost: e.target.value })}
                                                            />
                                                            <span className="absolute right-4 top-1/2 -translate-y-1/2 font-bold text-rose-300 text-xs uppercase">Ltrs</span>
                                                        </div>
                                                    </div>
                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-rose-600 tracking-widest">Avg Rate/Liter</Label>
                                                        <div className="relative">
                                                            <span className="absolute left-4 top-1/2 -translate-y-1/2 font-bold text-rose-300 text-xs">Rs.</span>
                                                            <Input
                                                                className="h-11 rounded-none pl-10 text-xl font-black num-audit border-rose-300 bg-white text-rose-900 focus:ring-0"
                                                                placeholder="0.00"
                                                                type="number"
                                                                value={form.rate_per_liter}
                                                                onChange={e => setForm({ ...form, rate_per_liter: e.target.value })}
                                                            />
                                                        </div>
                                                    </div>
                                                </div>
                                                <div className="p-4 bg-rose-100/50 border border-rose-200 flex items-center gap-3">
                                                    <AlertTriangle className="h-5 w-5 text-rose-600 shrink-0" />
                                                    <p className="text-[10px] font-bold text-rose-800 uppercase tracking-tight">
                                                        Warning: This operation will permanently reduce physical stock and debit 'Fuel Loss Expense'.
                                                    </p>
                                                </div>
                                            </>
                                        )}

                                        {/* 3. ASSET PURCHASE FLOW */}
                                        {txnType === 'ASSET_PURCHASE' && (
                                            <div className="space-y-8">
                                                <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-blue-600 tracking-widest">Asset Name / Title</Label>
                                                        <Input
                                                            className="h-11 rounded-none border-blue-300 focus:border-blue-600 font-bold text-blue-900 bg-white"
                                                            placeholder="e.g. Perkins 50kVA Generator"
                                                            value={form.asset_name}
                                                            onChange={e => setForm({ ...form, asset_name: e.target.value })}
                                                        />
                                                    </div>
                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-blue-600 tracking-widest">Asset Category</Label>
                                                        <Select value={form.asset_category} onValueChange={(val) => setForm({ ...form, asset_category: val })}>
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
                                                </div>
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-blue-600 tracking-widest">Purchase Amount (PKR)</Label>
                                                    <div className="relative">
                                                        <span className="absolute left-4 top-1/2 -translate-y-1/2 font-bold text-blue-300">Rs.</span>
                                                        <Input
                                                            className="h-11 rounded-none pl-12 text-xl font-black num-audit border-blue-300 focus:border-blue-600 focus:ring-0 text-blue-900 bg-white"
                                                            placeholder="0.00"
                                                            type="number"
                                                            value={form.amount}
                                                            onChange={e => setForm({ ...form, amount: e.target.value })}
                                                        />
                                                    </div>
                                                </div>
                                            </div>
                                        )}

                                        {/* 4. OWNER WITHDRAWAL FLOW */}
                                        {txnType === 'OWNER_WITHDRAWAL' && (
                                            <div className="space-y-2">
                                                <Label className="text-[10px] uppercase font-black text-amber-600 tracking-widest">Withdrawal Amount (PKR)</Label>
                                                <div className="relative">
                                                    <span className="absolute left-4 top-1/2 -translate-y-1/2 font-bold text-amber-300">Rs.</span>
                                                    <Input
                                                        className="h-11 rounded-none pl-12 text-xl font-black num-audit border-amber-300 focus:border-amber-600 focus:ring-0 text-amber-900 bg-white"
                                                        placeholder="0.00"
                                                        type="number"
                                                        value={form.amount}
                                                        onChange={e => setForm({ ...form, amount: e.target.value })}
                                                    />
                                                </div>
                                            </div>
                                        )}

                                        {/* NARRATION FIELD (SHARED) */}
                                        <div className="space-y-2 pt-4 border-t border-slate-200">
                                            <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest flex items-center gap-2">
                                                <PenTool className="h-3 w-3" /> Narration / Ledger Memo
                                            </Label>
                                            <Input
                                                className="h-11 rounded-none bg-white font-bold border-slate-300 placeholder:font-medium placeholder:italic text-slate-900"
                                                placeholder={
                                                    txnType === 'SHRINKAGE' ? "Brief reason for stock write-off..." :
                                                    txnType === 'ASSET_PURCHASE' ? "Describe vendor, warranty, or condition..." :
                                                    "Enter brief description of this transaction..."
                                                }
                                                value={txnType === 'SHRINKAGE' ? form.reason : form.narration}
                                                onChange={e => {
                                                    if (txnType === 'SHRINKAGE') setForm({ ...form, reason: e.target.value });
                                                    else setForm({ ...form, narration: e.target.value });
                                                }}
                                            />
                                        </div>
                                    </div>

                                    <Button 
                                        type="submit" 
                                        className={cn(
                                            "h-12 w-full text-white font-black text-xs uppercase tracking-[0.2em] rounded-none shadow-sm transition-all",
                                            txnType === 'ACTION_CENTER' ? "bg-emerald-600 hover:bg-emerald-700" :
                                            txnType === 'EXPENSE' ? "bg-slate-900 hover:bg-black" :
                                            txnType === 'SHRINKAGE' ? "bg-rose-600 hover:bg-rose-700" :
                                            txnType === 'ASSET_PURCHASE' ? "bg-blue-600 hover:bg-blue-700" :
                                            "bg-amber-600 hover:bg-amber-700"
                                        )}
                                        disabled={mutation.isPending}
                                    >
                                        {mutation.isPending ? <Loader2 className="animate-spin h-5 w-5 mr-2" /> : <CheckCircle2 className="h-4 w-4 mr-2" />}
                                        {mutation.isPending ? "PROCESSING..." : (txnType === 'ACTION_CENTER' ? "COMMIT MOVEMENT" : (isEditMode ? "COMMIT REVISIONS" : "FINALIZE TRANSACTION"))}
                                    </Button>
                                </form>
                            </div>
                        </div>
                    </div>

                    {/* ── RIGHT: SIDEBAR (HISTORY) ────────────────────────── */}
                    <div className="lg:col-span-4 space-y-6">
                        <div className="border border-slate-300 bg-white flex flex-col h-full max-h-[800px]">
                            <div className="px-6 py-3 bg-slate-100 border-b border-slate-200 flex items-center justify-between">
                                <h3 className="text-[10px] font-black uppercase text-slate-700 tracking-[0.2em] flex items-center gap-2">
                                    <History className="h-3.5 w-3.5" /> Recent Factory Output
                                </h3>
                            </div>
                            <div className="flex-1 overflow-y-auto">
                                {recentVouchers && recentVouchers.length > 0 ? (
                                    <div className="divide-y divide-slate-100">
                                        {recentVouchers.map((v: any) => {
                                            const isShrinkage = v.voucher_type === 'shrinkage';
                                            const isAsset = v.voucher_type === 'asset';
                                            const isAction = ['adjustment', 'receipt', 'payment'].includes(v.voucher_type);
                                            const isWithdrawal = v.voucher_type === 'withdrawal';
                                            
                                            const amount = v.debit_amount || v.credit_amount || 0;
                                            const name = v.party?.name || v.accounts?.name || 'General Entry';

                                            return (
                                                <div key={v.voucher_no} className="p-5 hover:bg-slate-50 transition-colors cursor-pointer group border-b border-slate-100 last:border-0" onClick={() => navigate(`/manage-transactions?edit=${v.voucher_no}`)}>
                                                    <div className="flex justify-between items-start mb-2">
                                                        <div className="flex items-center gap-2">
                                                            <span className={cn(
                                                                "text-[9px] font-mono font-black border px-2 py-0.5 rounded-none",
                                                                isAction ? "bg-emerald-50 border-emerald-200 text-emerald-600" :
                                                                isShrinkage ? "bg-rose-50 border-rose-200 text-rose-600" :
                                                                isAsset ? "bg-blue-50 border-blue-200 text-blue-600" :
                                                                isWithdrawal ? "bg-amber-50 border-amber-200 text-amber-600" :
                                                                "bg-slate-100 border-slate-200 text-slate-500"
                                                            )}>
                                                                {v.voucher_no}
                                                            </span>
                                                        </div>
                                                        <span className="text-[9px] font-black text-slate-400 uppercase tracking-widest">{v.posting_date}</span>
                                                    </div>
                                                    <div className="flex justify-between items-center">
                                                        <div className="flex-1 min-w-0 pr-4">
                                                            {isAction ? (
                                                                <p className="text-[11px] font-black text-emerald-700 uppercase leading-none mb-1 truncate flex items-center gap-1">
                                                                    {v.accounts?.name || 'Party'} <ArrowRight className="h-2 w-2" /> {name}
                                                                </p>
                                                            ) : (
                                                                <p className="text-[11px] font-black text-slate-800 uppercase leading-none mb-1 truncate">{name}</p>
                                                            )}
                                                            <p className="text-[10px] text-slate-400 line-clamp-1 italic font-medium">{v.narration}</p>
                                                        </div>
                                                        <div className="text-right">
                                                            <span className={cn(
                                                                "text-sm font-black num-audit tracking-tight",
                                                                isShrinkage ? "text-rose-600" : 
                                                                isAction ? "text-emerald-700" :
                                                                "text-slate-900"
                                                            )}>
                                                                {formatPKR(amount).replace('Rs. ', '')}
                                                            </span>
                                                        </div>
                                                    </div>
                                                </div>
                                            );
                                        })}
                                    </div>
                                ) : (
                                    <div className="p-12 text-center opacity-20">
                                        <AlertCircle className="h-10 w-10 text-slate-400 mx-auto mb-4" />
                                        <p className="text-[10px] font-black uppercase tracking-widest">Factory Idle</p>
                                    </div>
                                )}
                            </div>
                        </div>

                        {/* AUDIT NOTE */}
                        <div className="border border-slate-900 p-6 bg-slate-900 text-white">
                            <h4 className="text-[11px] font-black uppercase tracking-widest mb-3 border-b border-white/20 pb-2">Factory Governance</h4>
                            <div className="space-y-4">
                                <div className="flex items-start gap-3">
                                    <div className="h-4 w-4 rounded-full bg-emerald-500 shrink-0 mt-0.5" />
                                    <p className="text-[9px] text-slate-300 font-bold uppercase leading-relaxed">
                                        All transactions recorded here are automatically posted to the general ledger and impact real-time financial statements.
                                    </p>
                                </div>
                                <div className="flex items-start gap-3">
                                    <div className="h-4 w-4 rounded-full bg-rose-500 shrink-0 mt-0.5" />
                                    <p className="text-[9px] text-slate-300 font-bold uppercase leading-relaxed">
                                        Fuel shrinkage operations are audited against calculated stock levels. Over-recording is prevented by the core engine.
                                    </p>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <UnifiedAddAccountModal
                isOpen={isAddModalOpen}
                onOpenChange={setIsAddModalOpen}
                initialType="operating_expense"
                onSuccess={(id) => {
                    setForm(prev => ({ ...prev, expense_account_id: id }));
                }}
            />
        </DashboardLayout>
    );
}
