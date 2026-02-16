
import { useState, useRef, useEffect } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { Switch } from '@/components/ui/switch';
import {
    Select,
    SelectContent,
    SelectItem,
    SelectTrigger,
    SelectValue,
} from '@/components/ui/select';
import {
    Tabs,
    TabsContent,
    TabsList,
    TabsTrigger,
} from '@/components/ui/tabs';
import {
    AlertDialog,
    AlertDialogAction,
    AlertDialogContent,
    AlertDialogDescription,
    AlertDialogFooter,
    AlertDialogHeader,
    AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { useToast } from '@/hooks/use-toast';
import { formatPKR, formatNumber } from '@/lib/format';
import { Loader2, ArrowRightLeft, ShoppingCart, Truck, Search, UserPlus, AlertTriangle, CalendarDays, ChevronLeft, ChevronRight, CheckCircle2, History, Banknote } from 'lucide-react';
import { cn } from '@/lib/utils';
import { useInventory } from '@/hooks/useInventory';
import { QuickAddCustomer } from '@/components/QuickAddCustomer';

export default function ManageTransactions() {
    const navigate = useNavigate();
    const [searchParams] = useSearchParams();
    const queryClient = useQueryClient();
    const { toast } = useToast();
    const { user } = useAuth();
    const [activeTab, setActiveTab] = useState('online');
    const [isEditMode, setIsEditMode] = useState(false);
    const [editVoucherNo, setEditVoucherNo] = useState<string | null>(null);
    const [showPartyHistory, setShowPartyHistory] = useState(false);
    const [showSuccessModal, setShowSuccessModal] = useState(false);
    const [originalQty, setOriginalQty] = useState<number>(0);
    const partySelectRef = useRef<HTMLButtonElement>(null);

    // Deep-Edit Loader: Pulls original record and fills form
    useEffect(() => {
        const vNo = searchParams.get('edit');
        if (!vNo) return;

        const loadVoucher = async () => {
            setIsEditMode(true);
            setEditVoucherNo(vNo);

            // 1. Try Sales
            const { data: sale } = await supabase.from('sales').select('*').eq('voucher_no', vNo).maybeSingle();
            if (sale) {
                setActiveTab('sales');
                setSalesForm({
                    sale_date: sale.sale_date,
                    party_id: sale.party_id,
                    fuel_type_id: sale.fuel_type_id,
                    quantity: String(sale.quantity),
                    rate_per_unit: String(sale.rate_per_unit),
                    is_credit: sale.is_credit,
                    notes: sale.notes || ''
                });
                setOriginalQty(sale.quantity || 0);
                return;
            }

            // 2. Try Purchases
            const { data: purchase } = await supabase.from('purchases').select('*').eq('voucher_no', vNo).maybeSingle();
            if (purchase) {
                setActiveTab('purchases');
                setPurchaseForm({
                    purchase_date: purchase.purchase_date,
                    party_id: purchase.party_id,
                    fuel_type_id: purchase.fuel_type_id,
                    quantity: String(purchase.quantity),
                    rate_per_unit: String(purchase.rate_per_unit),
                    is_credit: !purchase.is_paid_now,
                    notes: purchase.notes || '',
                    is_paid_now: String(purchase.is_paid_now),
                    payment_method: purchase.payment_method || 'Cash'
                });
                return;
            }

            // 3. Try Online (Payments table)
            const { data: payment } = await supabase.from('payments').select('*, ledger_entries!inner(*)').eq('voucher_no', vNo).maybeSingle();
            if (payment) {
                // For online, we need to find who was 'From' and who was 'To' from ledger_entries
                const { data: entries } = await supabase.from('ledger_entries').select('*').eq('voucher_no', vNo);
                if (entries && entries.length >= 2) {
                    const fromEntry = entries.find(e => e.credit_amount > 0);
                    const toEntry = entries.find(e => e.debit_amount > 0);
                    setActiveTab('online');
                    setOnlineForm({
                        date: payment.payment_date,
                        from_id: fromEntry?.party_id || fromEntry?.account_id || '',
                        from_type: fromEntry?.party_id ? 'party' : 'account',
                        to_id: toEntry?.party_id || toEntry?.account_id || '',
                        to_type: toEntry?.party_id ? 'party' : 'account',
                        amount: String(payment.amount),
                        reference: '',
                        remarks: payment.notes || ''
                    });
                }
                return;
            }

            // 4. Fallback: Transfer vouchers (VCH-*) only exist in ledger_entries
            const { data: transferEntries } = await supabase.from('ledger_entries').select('*').eq('voucher_no', vNo);
            if (transferEntries && transferEntries.length >= 2) {
                const fromEntry = transferEntries.find(e => e.credit_amount > 0);
                const toEntry = transferEntries.find(e => e.debit_amount > 0);
                const amount = Math.max(...transferEntries.map(e => Math.max(Number(e.debit_amount) || 0, Number(e.credit_amount) || 0)));
                setActiveTab('online');
                setOnlineForm({
                    date: fromEntry?.posting_date || new Date().toISOString().split('T')[0],
                    from_id: fromEntry?.party_id || fromEntry?.account_id || '',
                    from_type: fromEntry?.party_id ? 'party' : 'account',
                    to_id: toEntry?.party_id || toEntry?.account_id || '',
                    to_type: toEntry?.party_id ? 'party' : 'account',
                    amount: String(amount),
                    reference: '',
                    remarks: (fromEntry?.narration || '').replace(/^Ref: N\/A - /, '').trim()
                });
            }
        };

        loadVoucher();
    }, [searchParams]);

    // Auto-focus on party selection when tab changes to 'online' or on mount
    useEffect(() => {
        if (activeTab === 'online' && !isEditMode) {
            const timer = setTimeout(() => {
                partySelectRef.current?.focus();
            }, 500);
            return () => clearTimeout(timer);
        }
    }, [activeTab]);

    const resetOnlineForm = () => {
        setOnlineForm({
            date: new Date().toISOString().split('T')[0],
            from_id: '',
            from_type: '',
            to_id: '',
            to_type: '',
            amount: '',
            reference: '',
            remarks: ''
        });
    };

    // --- SHARED DATA ---
    const { data: fuelTypes } = useQuery({
        queryKey: ['fuel-types'],
        queryFn: async () => {
            const { data } = await supabase.from('fuel_types').select('*').eq('is_active', true);
            return data;
        },
        staleTime: 5 * 60 * 1000, // 5 minutes — fuel types rarely change mid-session
    });

    const { data: inventoryData } = useInventory();

    // ------------------------------------------
    // TAB 1: ONLINE TRANSACTIONS (Money Transfer)
    // ------------------------------------------
    const [onlineForm, setOnlineForm] = useState({
        date: new Date().toISOString().split('T')[0],
        from_id: '',
        from_type: '',
        to_id: '',
        to_type: '',
        amount: '',
        reference: '',
        remarks: ''
    });

    const { data: historyData } = useQuery({
        queryKey: ['transaction-history', onlineForm.date, onlineForm.from_id, onlineForm.to_id, showPartyHistory],
        queryFn: async () => {
            let query = supabase
                .from('ledger_entries')
                .select(`
                    id, 
                    voucher_no, 
                    debit_amount, 
                    credit_amount, 
                    narration,
                    posting_date,
                    account:accounts(name),
                    party:parties(name)
                `);

            if (showPartyHistory && (onlineForm.from_id || onlineForm.to_id)) {
                // Show history for the selected party
                const partyId = onlineForm.from_id || onlineForm.to_id;
                query = query.eq('party_id', partyId);
            } else {
                // Default: Daily History
                query = query.eq('posting_date', onlineForm.date);
            }

            // FILTER: Only show Payments/Receipts in this view (Exclude Sales/Purchases)
            query = query.eq('voucher_type', 'payment');

            const { data, error } = await query.order('posting_date', { ascending: false }).order('created_at', { ascending: false });

            if (error) throw error;

            // Group by voucher_no
            const voucherGroups: Record<string, any> = {};
            data.forEach((entry: any) => {
                if (!voucherGroups[entry.voucher_no]) {
                    voucherGroups[entry.voucher_no] = {
                        id: entry.id,
                        date: entry.posting_date,
                        voucher_no: entry.voucher_no,
                        amount: Math.max(entry.debit_amount, entry.credit_amount),
                        remarks: (entry.narration || '').replace(/^Ref: N\/A - /, '').trim(),
                        from_name: entry.credit_amount > 0 ? (entry.party?.name || entry.account?.name) : '',
                        to_name: entry.debit_amount > 0 ? (entry.party?.name || entry.account?.name) : '',
                        debit: entry.debit_amount,
                        credit: entry.credit_amount
                    };
                } else {
                    if (entry.credit_amount > 0) voucherGroups[entry.voucher_no].from_name = entry.party?.name || entry.account?.name;
                    if (entry.debit_amount > 0) voucherGroups[entry.voucher_no].to_name = entry.party?.name || entry.account?.name;
                    if (entry.debit_amount > 0) voucherGroups[entry.voucher_no].debit = entry.debit_amount;
                    if (entry.credit_amount > 0) voucherGroups[entry.voucher_no].credit = entry.credit_amount;
                }
            });

            return Object.values(voucherGroups);
        }
    });

    // FETCH UNIFIED ACCOUNTS (Parties + System Accounts)
    const { data: allAccounts } = useQuery({
        queryKey: ['all-accounts-fresh'],
        queryFn: async () => {
            const [partiesRes, accRes] = await Promise.all([
                supabase.from('parties').select('id, name, type, current_balance').eq('is_active', true),
                supabase.from('accounts').select('id, name, account_type').eq('is_active', true).in('account_type', ['asset', 'liability'])
            ]);

            const systemKeywords = ['receivable', 'payable', 'control', 'inventory', 'cost of goods', 'sales', 'revenue', 'equity', 'capital', 'drawings', 'opening balance', 'retained earnings', 'advance'];

            // Map Parties
            const parties = (partiesRes.data || []).map(p => ({
                id: p.id,
                name: p.name,
                type: 'party',
                originalType: p.type,
                balance: p.current_balance
            }));

            // Map Accounts (Only Cash and Bank accounts as requested)
            const accounts = (accRes.data || [])
                .filter(a => {
                    const nameLower = a.name.toLowerCase();
                    return nameLower.includes('cash') || nameLower.includes('bank');
                })
                .map(a => ({ id: a.id, name: a.name, type: 'account', originalType: 'cash/bank', balance: 0 }));

            return [...parties, ...accounts].sort((a, b) => a.name.localeCompare(b.name));
        },
        staleTime: 30 * 1000, // 30 seconds — parties can be added but not every second
    });

    const p_narration_val = `Ref: ${onlineForm.reference || 'N/A'} - ${onlineForm.remarks || ''}`;

    const onlineMutation = useMutation({
        mutationFn: async (data: typeof onlineForm) => {
            if (!data.from_id || !data.to_id || !data.amount) throw new Error("Please fill all required fields");
            const fromEntity = allAccounts?.find(a => a.id === data.from_id);
            const toEntity = allAccounts?.find(a => a.id === data.to_id);
            if (!fromEntity || !toEntity) throw new Error("Invalid accounts");

            const { error } = await (supabase as any).rpc('post_munshi_voucher', {
                p_from_account_id: fromEntity.id,
                p_to_account_id: toEntity.id,
                p_amount: parseFloat(data.amount),
                p_narration: p_narration_val,
                p_date: data.date,
                p_voucher_no: isEditMode ? editVoucherNo : null
            });
            if (error) throw error;
            return true;
        },
        onSuccess: () => {
            toast({
                title: isEditMode ? 'Voucher Revised' : 'Transfer Recorded',
                description: isEditMode ? 'Old records scrubbed and new ones posted.' : 'Account balances adjusted.'
            });
            setShowSuccessModal(true);
            queryClient.invalidateQueries({ queryKey: ['roznamcha'] });
            queryClient.invalidateQueries({ queryKey: ['transaction-history'] });
            queryClient.invalidateQueries({ queryKey: ['calculated-inventory'] });
            queryClient.invalidateQueries({ queryKey: ['all-accounts-fresh'] });
            resetOnlineForm();
            if (isEditMode) {
                setIsEditMode(false);
                setEditVoucherNo(null);
                navigate('/manage-transactions'); // Clear query params
            }
        },
        onError: (e) => toast({ variant: 'destructive', title: 'Error', description: e.message })
    });


    // ------------------------------------------
    // TAB 2: SALES (Petrol Out)
    // ------------------------------------------
    const [salesForm, setSalesForm] = useState({
        sale_date: new Date().toISOString().split('T')[0],
        party_id: '',
        fuel_type_id: '',
        quantity: '',
        rate_per_unit: '',
        is_credit: false,
        notes: '',
    });
    const [quickAddOpen, setQuickAddOpen] = useState(false);
    const [quickAddType, setQuickAddType] = useState<'customer' | 'supplier'>('customer');

    const salesMutation = useMutation({
        mutationFn: async (data: typeof salesForm) => {
            if (!data.party_id) throw new Error("Please select a valid Account (Party)");

            // Stock Validation (Skip or warn on edit if complex, but simple check against current)
            if (!isEditMode) {
                const stockItem = inventoryData?.find(i => i.fuel_type_id === data.fuel_type_id);
                const currentStock = stockItem?.current_stock || 0;
                const requested = parseFloat(data.quantity);
                if (currentStock < requested) {
                    throw new Error(`ACCOUNTING INTEGRITY ALERT: Negative Stock is blocked. Current ${stockItem?.fuel_type_name} availability: ${formatNumber(currentStock)} L.`);
                }
            }

            const qty = parseFloat(data.quantity);
            const rate = parseFloat(data.rate_per_unit);
            const saleData = {
                sale_date: data.sale_date,
                party_id: data.party_id,
                fuel_type_id: data.fuel_type_id,
                quantity: qty,
                rate_per_unit: rate,
                total_amount: qty * rate,
                notes: data.notes
            };

            if (isEditMode && editVoucherNo) {
                const { error } = await supabase.from('sales').update(saleData).eq('voucher_no', editVoucherNo);
                if (error) throw error;
            } else {
                const { error } = await supabase.from('sales').insert({
                    ...saleData,
                    voucher_no: `SAL-${Date.now()}`,
                    is_credit: true,
                    created_by: user?.id
                } as any);
                if (error) throw error;
            }
            return true;
        },
        onSuccess: () => {
            toast({
                title: isEditMode ? 'Sale Revised' : 'Sale Recorded',
                description: isEditMode ? 'Stock and Ledger recalculated.' : 'Inventory deducted, Account debited.'
            });
            setSalesForm(prev => ({ ...prev, quantity: '', notes: '' }));
            queryClient.invalidateQueries({ queryKey: ['roznamcha'] });
            queryClient.invalidateQueries({ queryKey: ['transaction-history'] });
            queryClient.invalidateQueries({ queryKey: ['calculated-inventory'] });
            queryClient.invalidateQueries({ queryKey: ['all-accounts-fresh'] });
            if (isEditMode) {
                setIsEditMode(false);
                setEditVoucherNo(null);
                navigate('/manage-transactions');
            }
        },
        onError: (e) => toast({ variant: 'destructive', title: 'Sale Failed', description: e.message })
    });

    // Validations for Sales
    const selectedFuelStock = inventoryData?.find(i => i.fuel_type_id === salesForm.fuel_type_id);
    const availableStock = (selectedFuelStock?.current_stock || 0) + (isEditMode ? originalQty : 0);
    const requestedQty = parseFloat(salesForm.quantity) || 0;
    const hasInsufficientStock = requestedQty > availableStock && (selectedFuelStock?.current_stock || 0) >= 0;

    // ------------------------------------------
    // TAB 3: PURCHASES (Petrol In)
    // ------------------------------------------
    const [purchaseForm, setPurchaseForm] = useState({
        purchase_date: new Date().toISOString().split('T')[0],
        party_id: '',
        fuel_type_id: '',
        quantity: '',
        rate_per_unit: '',
        is_credit: false,
        notes: '',
        is_paid_now: 'false',
        payment_method: 'Cash'
    });

    const purchaseMutation = useMutation({
        mutationFn: async (data: typeof purchaseForm) => {
            if (!data.party_id) throw new Error("Please select a Supplier/Account");
            const qty = parseFloat(data.quantity);
            const rate = parseFloat(data.rate_per_unit);

            const payload: any = {
                purchase_date: data.purchase_date,
                party_id: data.party_id,
                fuel_type_id: data.fuel_type_id,
                quantity: qty,
                rate_per_unit: rate,
                total_amount: qty * rate,
                notes: data.notes,
                payment_method: data.payment_method || 'Cash'
            };

            if (isEditMode && editVoucherNo) {
                const { error } = await supabase.from('purchases').update(payload).eq('voucher_no', editVoucherNo);
                if (error) throw error;
            } else {
                const { error } = await supabase.from('purchases').insert({
                    ...payload,
                    voucher_no: `PUR-${Date.now()}`,
                    created_by: user?.id,
                    is_paid_now: false // Force Credit-First
                } as any);
                if (error) throw error;
            }
            return true;
        },
        onSuccess: () => {
            toast({
                title: isEditMode ? 'Purchase Revised' : 'Purchase Recorded',
                description: isEditMode ? 'Inventory and Ledger synchronized.' : 'Inventory added, Account credited.'
            });
            setPurchaseForm(prev => ({ ...prev, quantity: '', notes: '' }));
            queryClient.invalidateQueries({ queryKey: ['roznamcha'] });
            queryClient.invalidateQueries({ queryKey: ['transaction-history'] });
            queryClient.invalidateQueries({ queryKey: ['calculated-inventory'] });
            queryClient.invalidateQueries({ queryKey: ['all-accounts-fresh'] });
            if (isEditMode) {
                setIsEditMode(false);
                setEditVoucherNo(null);
                navigate('/manage-transactions');
            }
        },
        onError: (e) => toast({ variant: 'destructive', title: 'Purchase Failed', description: e.message })
    });


    return (
        <DashboardLayout>
            <div className="max-w-[1600px] mx-auto space-y-8 p-1">
                {/* --- HEADER --- */}
                <div className="flex flex-col md:flex-row md:items-end justify-between gap-4 border-b border-slate-200 pb-6">
                    <div>
                        <h1 className="text-2xl md:text-3xl font-black tracking-tighter text-slate-900 uppercase">
                            {isEditMode ? "Voucher Revision" : "Financial Operations"}
                        </h1>
                        <p className="text-xs text-slate-500 font-medium mt-1">
                            {isEditMode ? `Modifying original entry for ${editVoucherNo}. Changes will auto-reconcile stock.` : "Record payments, credit sales, and procurement."}
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
                                resetOnlineForm();
                                setSalesForm(prev => ({ ...prev, quantity: '', notes: '' }));
                                setPurchaseForm(prev => ({ ...prev, quantity: '', notes: '' }));
                                navigate('/manage-transactions');
                            }}
                        >
                            Abort Edit & Exit
                        </Button>
                    )}
                </div>

                {/* --- TABS --- */}
                <Tabs value={activeTab} onValueChange={setActiveTab} className="w-full space-y-8">
                    <TabsList className="bg-slate-100/50 p-1 rounded-xl flex flex-col md:flex-row gap-2 h-auto w-full md:w-fit border border-slate-200">
                        <TabsTrigger value="online" className="h-10 px-4 md:px-6 rounded-lg font-bold data-[state=active]:bg-slate-900 data-[state=active]:text-white transition-all shadow-sm w-full md:w-auto text-[11px] md:text-sm">
                            <ArrowRightLeft className="mr-2 h-4 w-4" /> Transfer
                        </TabsTrigger>
                        <TabsTrigger value="sales" className="h-10 px-4 md:px-6 rounded-lg font-bold data-[state=active]:bg-emerald-600 data-[state=active]:text-white transition-all shadow-sm w-full md:w-auto text-[11px] md:text-sm">
                            <ShoppingCart className="mr-2 h-4 w-4" /> Credit Sale
                        </TabsTrigger>
                        <TabsTrigger value="purchases" className="h-10 px-4 md:px-6 rounded-lg font-bold data-[state=active]:bg-rose-600 data-[state=active]:text-white transition-all shadow-sm w-full md:w-auto text-[11px] md:text-sm">
                            <Truck className="mr-2 h-4 w-4" /> Purchase Entry
                        </TabsTrigger>
                    </TabsList>

                    {/* --- TAB 1: ONLINE (PAYMENTS) --- */}
                    <TabsContent value="online" className="animate-in fade-in slide-in-from-bottom-3 duration-500 space-y-8">

                        {/* INPUT CARD */}
                        <div className="grid grid-cols-1 lg:grid-cols-12 gap-8">
                            <div className="lg:col-span-8 space-y-6">
                                <div className="bg-white rounded-2xl border border-slate-200 shadow-sm overflow-hidden">
                                    <div className="bg-slate-50/50 px-6 py-4 border-b border-slate-100 flex items-center justify-between">
                                        <h3 className="font-extrabold text-slate-700 text-sm uppercase tracking-wider flex items-center gap-2">
                                            <Banknote className="h-4 w-4 text-slate-400" /> Payment Voucher
                                        </h3>
                                        {/* Date Navigator */}
                                        <div className="flex items-center gap-2 bg-white rounded-lg border shadow-sm p-1">
                                            <Button variant="ghost" size="icon" className="h-6 w-6" onClick={() => {
                                                const d = new Date(onlineForm.date);
                                                d.setDate(d.getDate() - 1);
                                                setOnlineForm({ ...onlineForm, date: d.toISOString().split('T')[0] });
                                            }}><ChevronLeft className="h-3 w-3" /></Button>
                                            <span className="text-xs font-mono font-bold w-24 text-center">{onlineForm.date}</span>
                                            <Button variant="ghost" size="icon" className="h-6 w-6" onClick={() => {
                                                const d = new Date(onlineForm.date);
                                                d.setDate(d.getDate() + 1);
                                                setOnlineForm({ ...onlineForm, date: d.toISOString().split('T')[0] });
                                            }}><ChevronRight className="h-3 w-3" /></Button>
                                        </div>
                                    </div>

                                    <div className="p-8">
                                        <form onSubmit={(e) => { e.preventDefault(); onlineMutation.mutate(onlineForm); }} className="space-y-8">
                                            {/* Transaction Flow Visualizer */}
                                            <div className="flex flex-col md:flex-row gap-4 items-center bg-slate-50 p-6 rounded-xl border border-slate-100 relative">

                                                {/* GIVER */}
                                                <div className="w-full space-y-2 relative z-10">
                                                    <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Money From (Giver)</Label>
                                                    <Select value={onlineForm.from_id} onValueChange={(val) => {
                                                        const acc = allAccounts?.find(a => a.id === val);
                                                        setOnlineForm(prev => ({ ...prev, from_id: val, from_type: acc?.type || '' }));
                                                    }}>
                                                        <SelectTrigger ref={partySelectRef} className="h-12 bg-white font-bold border-slate-200 shadow-sm focus:ring-slate-900"><SelectValue placeholder="Select Source..." /></SelectTrigger>
                                                        <SelectContent>
                                                            {allAccounts?.map(a => <SelectItem key={a.id} value={a.id} className="font-medium">{a.name}</SelectItem>)}
                                                        </SelectContent>
                                                    </Select>
                                                </div>

                                                {/* DIRECTION ARROW */}
                                                <div className="hidden md:flex flex-col items-center justify-center pt-6 text-slate-300">
                                                    <ArrowRightLeft className="h-6 w-6" />
                                                </div>

                                                {/* RECEIVER */}
                                                <div className="w-full space-y-2 relative z-10">
                                                    <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Money To (Receiver)</Label>
                                                    <Select value={onlineForm.to_id} onValueChange={(val) => {
                                                        const acc = allAccounts?.find(a => a.id === val);
                                                        setOnlineForm(prev => ({ ...prev, to_id: val, to_type: acc?.type || '' }));
                                                    }}>
                                                        <SelectTrigger className="h-12 bg-white font-bold border-slate-200 shadow-sm focus:ring-slate-900"><SelectValue placeholder="Select Destination..." /></SelectTrigger>
                                                        <SelectContent>
                                                            {allAccounts?.map(a => <SelectItem key={a.id} value={a.id} className="font-medium">{a.name}</SelectItem>)}
                                                        </SelectContent>
                                                    </Select>
                                                </div>
                                            </div>

                                            {/* DETAILS */}
                                            <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-12 gap-4 md:gap-6 items-end">
                                                <div className="md:col-span-4 space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Amount (PKR)</Label>
                                                    <div className="relative">
                                                        <span className="absolute left-4 top-1/2 -translate-y-1/2 font-bold text-slate-400">Rs.</span>
                                                        <Input
                                                            className="h-14 pl-12 text-xl font-black tracking-tight border-slate-200 focus:border-slate-400 focus:ring-0"
                                                            placeholder="0"
                                                            type="number"
                                                            value={onlineForm.amount}
                                                            onChange={e => setOnlineForm({ ...onlineForm, amount: e.target.value })}
                                                        />
                                                    </div>
                                                </div>
                                                <div className="md:col-span-4 space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Reference</Label>
                                                    <Input className="h-14 font-medium border-slate-200" placeholder="#Ref-001" value={onlineForm.reference} onChange={e => setOnlineForm({ ...onlineForm, reference: e.target.value })} />
                                                </div>
                                                <div className="sm:col-span-2 md:col-span-4 flex items-end">
                                                    <Button type="submit" className="h-14 w-full bg-slate-900 hover:bg-slate-800 text-white font-bold text-base shadow-slate-900/20 shadow-lg tracking-wide" disabled={onlineMutation.isPending}>
                                                        {onlineMutation.isPending ? <Loader2 className="animate-spin h-5 w-5 mr-2" /> : <CheckCircle2 className="h-5 w-5 mr-2" />}
                                                        {onlineMutation.isPending ? "PROCESSING..." : (isEditMode ? "COMMIT REVISIONS" : "CONFIRM TRANSFER")}
                                                    </Button>
                                                </div>
                                            </div>
                                            <div className="space-y-2">
                                                <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Remarks</Label>
                                                <Input className="h-11 border-slate-200 bg-slate-50/50" placeholder="Optional notes..." value={onlineForm.remarks} onChange={e => setOnlineForm({ ...onlineForm, remarks: e.target.value })} />
                                            </div>
                                        </form>
                                    </div>
                                </div>
                            </div>

                            {/* HISTORY SIDEBAR */}
                            <div className="lg:col-span-4 space-y-4">
                                <div className="flex items-center justify-between">
                                    <h3 className="text-sm font-bold text-slate-500 uppercase flex items-center gap-2">
                                        <History className="h-4 w-4" /> Recent Ledger
                                    </h3>
                                    <div className="flex items-center gap-2">
                                        <Label htmlFor="hist-toggle" className="text-[10px] font-bold uppercase cursor-pointer">Filter Party</Label>
                                        <Switch id="hist-toggle" checked={showPartyHistory} onCheckedChange={setShowPartyHistory} />
                                    </div>
                                </div>
                                <div className="bg-white rounded-xl border border-slate-200 shadow-sm overflow-hidden h-[500px] flex flex-col">
                                    <div className="overflow-y-auto flex-1 p-0">
                                        {historyData && historyData.length > 0 ? (
                                            <div className="divide-y divide-slate-100">
                                                {historyData.map((txn: any) => (
                                                    <div key={txn.id} className="p-4 hover:bg-slate-50 transition-colors group">
                                                        <div className="flex justify-between items-start mb-1">
                                                            <span className="text-[10px] font-mono font-bold text-slate-400 bg-slate-100 px-1.5 py-0.5 rounded">{txn.voucher_no}</span>
                                                            <span className="text-[10px] font-bold text-slate-400">{txn.date}</span>
                                                        </div>
                                                        <div className="flex justify-between items-center mb-1">
                                                            <div className="flex flex-col">
                                                                <span className="text-xs font-bold text-slate-700">{txn.from_name} <span className="text-slate-300 mx-1">→</span> {txn.to_name}</span>
                                                            </div>
                                                            <span className="font-extrabold text-slate-900">{formatPKR(txn.amount)}</span>
                                                        </div>
                                                        <p className="text-[10px] text-slate-400 line-clamp-1 italic">{txn.remarks}</p>
                                                    </div>
                                                ))}
                                            </div>
                                        ) : (
                                            <div className="h-full flex flex-col items-center justify-center text-slate-400 p-8 text-center">
                                                <AlertTriangle className="h-8 w-8 mb-2 opacity-20" />
                                                <p className="text-xs font-medium">No transactions found for this date/filter.</p>
                                            </div>
                                        )}
                                    </div>
                                </div>
                            </div>
                        </div>

                        {/* Confirmation Modal */}
                        <AlertDialog open={showSuccessModal} onOpenChange={setShowSuccessModal}>
                            <AlertDialogContent className="bg-white border-none shadow-2xl rounded-2xl">
                                <AlertDialogHeader>
                                    <div className="mx-auto bg-green-100 h-16 w-16 rounded-full flex items-center justify-center mb-4">
                                        <CheckCircle2 className="h-8 w-8 text-green-600" />
                                    </div>
                                    <AlertDialogTitle className="text-center text-xl font-black text-slate-900">Transaction Successful</AlertDialogTitle>
                                    <AlertDialogDescription className="text-center font-medium text-slate-500">
                                        The payment has been securely recorded in the ledger.
                                    </AlertDialogDescription>
                                </AlertDialogHeader>
                                <AlertDialogFooter className="sm:justify-center">
                                    <AlertDialogAction className="bg-slate-900 hover:bg-slate-800 font-bold px-8">CLOSE</AlertDialogAction>
                                </AlertDialogFooter>
                            </AlertDialogContent>
                        </AlertDialog>
                    </TabsContent>

                    {/* --- TAB 2: SALES --- */}
                    <TabsContent value="sales" className="animate-in fade-in slide-in-from-bottom-3 duration-500">
                        <div className="grid grid-cols-1 lg:grid-cols-6 gap-8">
                            <div className="lg:col-span-4 space-y-6">
                                <div className="bg-white rounded-2xl border border-emerald-100 shadow-sm overflow-hidden">
                                    <div className="bg-emerald-50/50 px-6 py-4 border-b border-emerald-100 flex items-center justify-between">
                                        <h3 className="font-extrabold text-emerald-800 text-sm uppercase tracking-wider flex items-center gap-2">
                                            <ShoppingCart className="h-4 w-4 text-emerald-600" /> Credit Sale (Udhaar)
                                        </h3>
                                        <Button variant="ghost" size="sm" onClick={() => { setQuickAddType('customer'); setQuickAddOpen(true); }} className="text-emerald-700 hover:bg-emerald-100 text-xs font-bold gap-1">
                                            <UserPlus className="h-3 w-3" /> New Customer
                                        </Button>
                                    </div>
                                    <div className="p-8">
                                        <form onSubmit={(e) => { e.preventDefault(); salesMutation.mutate(salesForm); }} className="space-y-6">
                                            <div className="space-y-2">
                                                <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Customer Account</Label>
                                                <Select value={salesForm.party_id} onValueChange={(val) => setSalesForm({ ...salesForm, party_id: val })}>
                                                    <SelectTrigger className="h-12 border-emerald-100 font-bold text-slate-800"><SelectValue placeholder="Select Customer..." /></SelectTrigger>
                                                    <SelectContent>
                                                        {allAccounts?.filter(a => a.type === 'party').map(c => <SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>)}
                                                    </SelectContent>
                                                </Select>
                                            </div>

                                            <div className="grid grid-cols-2 gap-6">
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Fuel Type</Label>
                                                    <Select value={salesForm.fuel_type_id} onValueChange={(val) => setSalesForm({ ...salesForm, fuel_type_id: val })}>
                                                        <SelectTrigger className="h-12 border-emerald-100 font-bold"><SelectValue placeholder="Select Product..." /></SelectTrigger>
                                                        <SelectContent>
                                                            {fuelTypes?.map(f => {
                                                                const stock = inventoryData?.find(i => i.fuel_type_id === f.id)?.current_stock || 0;
                                                                return <SelectItem key={f.id} value={f.id}>{f.name} <span className="text-xs text-slate-400 ml-1">({formatNumber(stock)} L)</span></SelectItem>
                                                            })}
                                                        </SelectContent>
                                                    </Select>
                                                </div>
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Liters</Label>
                                                    <Input className={cn("h-12 font-bold border-emerald-100", hasInsufficientStock ? "border-red-500 ring-1 ring-red-500" : "")} type="number" value={salesForm.quantity} onChange={e => setSalesForm({ ...salesForm, quantity: e.target.value })} />
                                                    {hasInsufficientStock && <span className="text-[10px] text-red-600 font-black animate-pulse block text-right">⚠️ INSUFFICIENT STOCK</span>}
                                                </div>
                                            </div>

                                            <div className="grid grid-cols-2 gap-6">
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Rate / Liter</Label>
                                                    <Input className="h-12 font-bold border-emerald-100" type="number" step="0.01" value={salesForm.rate_per_unit} onChange={e => setSalesForm({ ...salesForm, rate_per_unit: e.target.value })} />
                                                </div>
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Total</Label>
                                                    <div className="h-12 bg-emerald-50 rounded-lg flex items-center justify-end px-4 font-mono text-lg font-bold text-emerald-800">
                                                        {formatPKR((parseFloat(salesForm.quantity) || 0) * (parseFloat(salesForm.rate_per_unit) || 0))}
                                                    </div>
                                                </div>
                                            </div>

                                            <div className="space-y-2">
                                                <Label className="text-[10px] uppercase font-black text-emerald-600 tracking-wider pl-1">Details (Driver / Vehicle / Remarks)</Label>
                                                <Textarea
                                                    className="min-h-[80px] border-emerald-100 font-medium bg-emerald-50/20"
                                                    placeholder="Example: Driver Sami, Truck #KPK-1234, Cell: 0312..."
                                                    value={salesForm.notes}
                                                    onChange={e => setSalesForm({ ...salesForm, notes: e.target.value })}
                                                />
                                            </div>

                                            <Button type="submit" className="h-14 w-full bg-emerald-600 hover:bg-emerald-700 text-white font-bold text-base shadow-lg shadow-emerald-900/10 tracking-wide mt-4" disabled={salesMutation.isPending || hasInsufficientStock}>
                                                {salesMutation.isPending ? <Loader2 className="animate-spin h-5 w-5 mr-2" /> : <ShoppingCart className="h-5 w-5 mr-2" />}
                                                {hasInsufficientStock ? "STOCK BLOCKED" : (isEditMode ? "UPDATE REVISED SALE" : "POST CREDIT SALE")}
                                            </Button>
                                        </form>
                                    </div>
                                </div>
                            </div>

                            {/* Tips Panel */}
                            <div className="lg:col-span-2 space-y-6">
                                <div className="bg-emerald-50/50 p-6 rounded-2xl border border-emerald-100/50">
                                    <h4 className="font-bold text-emerald-800 mb-2 flex items-center gap-2"><ArrowRightLeft className="h-4 w-4" /> Accounting Note</h4>
                                    <p className="text-xs text-emerald-700/80 leading-relaxed">
                                        This creates a <strong>Credit Sale</strong>. The customer's balance will increase (Receivable). You must record a separate "Received" entry when they pay.
                                    </p>
                                </div>
                            </div>
                        </div>
                    </TabsContent>

                    {/* --- TAB 3: PURCHASES --- */}
                    <TabsContent value="purchases" className="animate-in fade-in slide-in-from-bottom-3 duration-500">
                        <div className="grid grid-cols-1 lg:grid-cols-6 gap-8">
                            <div className="lg:col-span-4 space-y-6">
                                <div className="bg-white rounded-2xl border border-rose-100 shadow-sm overflow-hidden">
                                    <div className="bg-rose-50/50 px-6 py-4 border-b border-rose-100 flex items-center justify-between">
                                        <h3 className="font-extrabold text-rose-800 text-sm uppercase tracking-wider flex items-center gap-2">
                                            <Truck className="h-4 w-4 text-rose-600" /> Stock Purchase
                                        </h3>
                                        <Button variant="ghost" size="sm" onClick={() => { setQuickAddType('supplier'); setQuickAddOpen(true); }} className="text-rose-700 hover:bg-rose-100 text-xs font-bold gap-1">
                                            <UserPlus className="h-3 w-3" /> New Supplier
                                        </Button>
                                    </div>
                                    <div className="p-8">
                                        <form onSubmit={(e) => { e.preventDefault(); purchaseMutation.mutate(purchaseForm); }} className="space-y-6">
                                            <div className="space-y-2">
                                                <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Supplier Account</Label>
                                                <Select value={purchaseForm.party_id} onValueChange={(val) => setPurchaseForm({ ...purchaseForm, party_id: val })}>
                                                    <SelectTrigger className="h-12 border-rose-100 font-bold text-slate-800"><SelectValue placeholder="Select Supplier..." /></SelectTrigger>
                                                    <SelectContent>
                                                        {allAccounts?.filter(a => a.type === 'party').map(s => <SelectItem key={s.id} value={s.id}>{s.name}</SelectItem>)}
                                                    </SelectContent>
                                                </Select>
                                            </div>

                                            <div className="grid grid-cols-2 gap-6">
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Fuel Type</Label>
                                                    <Select value={purchaseForm.fuel_type_id} onValueChange={(val) => setPurchaseForm({ ...purchaseForm, fuel_type_id: val })}>
                                                        <SelectTrigger className="h-12 border-rose-100 font-bold"><SelectValue placeholder="Select Fuel..." /></SelectTrigger>
                                                        <SelectContent>
                                                            {fuelTypes?.map(f => <SelectItem key={f.id} value={f.id}>{f.name}</SelectItem>)}
                                                        </SelectContent>
                                                    </Select>
                                                </div>
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Quantity (L)</Label>
                                                    <Input className="h-12 font-bold border-rose-100" type="number" value={purchaseForm.quantity} onChange={e => setPurchaseForm({ ...purchaseForm, quantity: e.target.value })} />
                                                </div>
                                            </div>

                                            <div className="grid grid-cols-2 gap-6">
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Cost Rate (PKR)</Label>
                                                    <Input className="h-12 font-bold border-rose-100" type="number" step="0.01" value={purchaseForm.rate_per_unit} onChange={e => setPurchaseForm({ ...purchaseForm, rate_per_unit: e.target.value })} />
                                                </div>
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-slate-400 tracking-wider pl-1">Total Payable</Label>
                                                    <div className="h-12 bg-rose-50 rounded-lg flex items-center justify-end px-4 font-mono text-lg font-bold text-rose-800">
                                                        {formatPKR((parseFloat(purchaseForm.quantity) || 0) * (parseFloat(purchaseForm.rate_per_unit) || 0))}
                                                    </div>
                                                </div>
                                            </div>

                                            <div className="space-y-2">
                                                <Label className="text-[10px] uppercase font-black text-rose-600 tracking-wider pl-1">Details (Vessel / Truck / Driver / Remarks)</Label>
                                                <Textarea
                                                    className="min-h-[80px] border-rose-100 font-medium bg-rose-50/20"
                                                    placeholder="Example: PSO Supply, Driver Naveed, Truck #ISB-556, Notes..."
                                                    value={purchaseForm.notes}
                                                    onChange={e => setPurchaseForm({ ...purchaseForm, notes: e.target.value })}
                                                />
                                            </div>

                                            <Button type="submit" className="h-14 w-full bg-rose-600 hover:bg-rose-700 text-white font-bold text-base shadow-lg shadow-rose-900/10 tracking-wide mt-4" disabled={purchaseMutation.isPending}>
                                                {purchaseMutation.isPending ? <Loader2 className="animate-spin h-5 w-5 mr-2" /> : <Truck className="h-5 w-5 mr-2" />}
                                                {isEditMode ? "COMMIT PURCHASE UPDATES" : "POST STOCK ENTRY"}
                                            </Button>
                                        </form>
                                    </div>
                                </div>
                            </div>
                        </div>
                    </TabsContent>
                </Tabs>
            </div>

            <QuickAddCustomer
                open={quickAddOpen}
                onOpenChange={setQuickAddOpen}
                type={quickAddType as 'customer' | 'supplier'}
                onCustomerCreated={(id) => {
                    if (quickAddType === 'customer') {
                        setSalesForm(prev => ({ ...prev, party_id: id }));
                    } else {
                        setPurchaseForm(prev => ({ ...prev, party_id: id }));
                    }
                }}
            />
        </DashboardLayout>
    );
}
