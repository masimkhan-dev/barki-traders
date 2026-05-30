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
// Removed assertPhase1CreateOnly import
import { useToast } from '@/hooks/use-toast';
import { formatPKR } from '@/lib/format';
import {
    Loader2,
    Wallet,
    History,
    CheckCircle2,
    AlertCircle,
    PlusCircle,
    ArrowRightLeft,
    AlertTriangle,
    Calendar,
    PenTool,
    Users,
    Building,
    ArrowRight,
    TrendingDown,
    TrendingUp,
} from 'lucide-react';
import { UnifiedAddAccountModal } from '@/components/accounting/UnifiedAddAccountModal';
import { cn } from '@/lib/utils';

type TransactionType =
    | 'SALE'
    | 'PURCHASE'
    | 'EXPENSE'
    | 'ACTION_CENTER'
    | 'SHRINKAGE'
    | 'ASSET_PURCHASE'
    | 'OWNER_WITHDRAWAL';

const TODAY = new Date().toISOString().split('T')[0];

const INITIAL_FORM_STATE = {
    date: TODAY,
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
    from_type: 'party' as 'party' | 'account',
    to_entity_id: '',
    to_type: 'account' as 'party' | 'account',
    action_type: 'transfer' as 'transfer' | 'receipt' | 'payment' | 'contra',
    party_id: '',
    quantity: '',
    rate: '',
    is_credit: true,
    is_paid_now: false,
    payment_method: 'Cash',
};

type FormState = typeof INITIAL_FORM_STATE;

type RpcResult = {
    success?: boolean;
    error?: string;
    message?: string;
    [key: string]: unknown;
};

const numericOrZero = (value: string) => Number.parseFloat(value || '0');

const readableErrorMessage = (value: unknown, fallbackMessage: string) => {
    if (!value) return fallbackMessage;
    if (value instanceof Error) return value.message || fallbackMessage;
    if (typeof value === 'string') return value || fallbackMessage;
    if (typeof value === 'object') {
        const errorObject = value as { message?: unknown; error?: unknown; details?: unknown; hint?: unknown; code?: unknown };
        const parts = [errorObject.message, errorObject.error, errorObject.details, errorObject.hint, errorObject.code]
            .filter(Boolean)
            .map(String);

        if (parts.length > 0) return parts.join(' ');

        try {
            return JSON.stringify(value);
        } catch {
            return fallbackMessage;
        }
    }
    return String(value) || fallbackMessage;
};

const assertRpcSuccess = <T extends RpcResult | null>(data: T, error: unknown, fallbackMessage: string): T => {
    if (error) {
        const message = readableErrorMessage(error, fallbackMessage);
        throw new Error(message || fallbackMessage);
    }

    if (data && data.success === false) {
        throw new Error(readableErrorMessage(data.error || data.message, fallbackMessage));
    }

    return data;
};

const tabClassMap: Record<string, { active: string; inactiveIcon: string }> = {
    emerald: {
        active: 'bg-emerald-600 border-emerald-500 text-white shadow-[0_0_15px_rgba(0,0,0,0.3)]',
        inactiveIcon: 'text-slate-500',
    },
    rose: {
        active: 'bg-rose-600 border-rose-500 text-white shadow-[0_0_15px_rgba(0,0,0,0.3)]',
        inactiveIcon: 'text-slate-500',
    },
    slate: {
        active: 'bg-slate-600 border-slate-500 text-white shadow-[0_0_15px_rgba(0,0,0,0.3)]',
        inactiveIcon: 'text-slate-500',
    },
    blue: {
        active: 'bg-blue-600 border-blue-500 text-white shadow-[0_0_15px_rgba(0,0,0,0.3)]',
        inactiveIcon: 'text-slate-500',
    },
    amber: {
        active: 'bg-amber-600 border-amber-500 text-white shadow-[0_0_15px_rgba(0,0,0,0.3)]',
        inactiveIcon: 'text-slate-500',
    },
};

const TRANSACTION_QUERY_ROOTS = new Set<string>([
    'roznamcha',
    'roznamcha-v2',
    'roznamcha-v3',
    'recent-factory-vouchers',
    'transaction-history',
    'calculated-inventory',
    'inventory',
    'inventory-mini-v10',
    'inventory_movements',
    'sales',
    'purchases',
    'report-sales',
    'report-purchases',
    'report-payments-rpc',
    'report-market-position',
    'report-drawings',
    'ledger_entries',
    'ledger_balances',
    'party-statement',
    'party-statement-v8',
    'party-product-summary-v8',
    'customer-khata',
    'supplier-khata',
    'account-ledger',
    'dashboard-analytics-v11-2',
    'recent-activities-v1',
    'dashboard-feed',
    'daily-summary',
    'daily-transactions',
    'account-balances',
    'profit-loss-rpc',
    'pnl-v13-grouped',
    'pnl-rpc-v2',
    'trial-balance-pro',
    'balance-sheet-v13',
    'balance-sheet',
    'capital-report',
    'fixed-assets-report',
    'drawings-report',
    'all-accounts-fresh',
    'accounts-all-active',
    'parties-active',
    'fuel-types-active',
]);

const isTransactionCacheQuery = (queryKey: readonly unknown[]) => {
    const root = queryKey[0];
    return typeof root === 'string' && TRANSACTION_QUERY_ROOTS.has(root);
};

export default function ManageTransactions() {
    const navigate = useNavigate();
    const [searchParams] = useSearchParams();
    const queryClient = useQueryClient();
    const { toast } = useToast();

    const [txnType, setTxnType] = useState<TransactionType>('SALE');
    const [isEditMode, setIsEditMode] = useState(false);
    const [editVoucherNo, setEditVoucherNo] = useState<string | null>(null);
    const [isAddModalOpen, setIsAddModalOpen] = useState(false);
    const [form, setForm] = useState<FormState>(INITIAL_FORM_STATE);

    const resetForm = (dateToKeep: string = TODAY) => {
        setForm({
            ...INITIAL_FORM_STATE,
            date: dateToKeep,
        });
    };

    const clearEditMode = () => {
        setIsEditMode(false);
        setEditVoucherNo(null);
        navigate('/manage-transactions');
    };

    const invalidateTransactionQueries = async () => {
        await queryClient.invalidateQueries({
            predicate: query => isTransactionCacheQuery(query.queryKey),
        });
    };

    const handleTabChange = (type: TransactionType) => {
        if (isEditMode) {
            clearEditMode();
        }
        setTxnType(type);
        resetForm(form.date);
    };

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

        if (vNo) {
            setIsEditMode(true);
            setEditVoucherNo(vNo);
            // Fetch the existing voucher details here if needed, or rely on another component.
        }
    }, [searchParams, toast, navigate]);

    const { data: editData } = useQuery({
        queryKey: ['edit-transaction', editVoucherNo, txnType],
        queryFn: async () => {
            if (!editVoucherNo) return null;
            if (txnType === 'SALE') {
                const { data, error } = await supabase.from('sales').select('*').eq('voucher_no', editVoucherNo).single();
                if (error) throw error;
                return data;
            } else if (txnType === 'PURCHASE') {
                const { data, error } = await supabase.from('purchases').select('*').eq('voucher_no', editVoucherNo).single();
                if (error) throw error;
                return data;
            }
            return null;
        },
        enabled: !!editVoucherNo && (txnType === 'SALE' || txnType === 'PURCHASE'),
    });

    useEffect(() => {
        if (editData && isEditMode) {
            setForm(prev => ({
                ...prev,
                date: editData.sale_date || editData.purchase_date || TODAY,
                party_id: editData.party_id || '',
                fuel_type_id: editData.fuel_type_id || '',
                quantity: editData.quantity?.toString() || '',
                rate: editData.rate_per_unit?.toString() || '',
                narration: editData.notes || '',
                is_credit: editData.is_credit ?? true,
                is_paid_now: editData.is_paid_now ?? false,
                payment_method: editData.payment_method || 'Cash',
            }));
        }
    }, [editData, isEditMode]);

    const { data: expenseAccounts } = useQuery({
        queryKey: ['accounts-expense'],
        queryFn: async () => {
            const { data, error } = await supabase
                .from('accounts')
                .select('id, name, code')
                .eq('account_type', 'expense')
                .eq('is_active', true)
                .order('code');
            if (error) throw error;
            return data || [];
        },
    });

    const { data: paymentAccounts } = useQuery({
        queryKey: ['accounts-payment'],
        queryFn: async () => {
            const { data, error } = await supabase
                .from('accounts')
                .select('id, name, code')
                .eq('account_type', 'asset')
                .or('name.ilike.%cash%,name.ilike.%bank%')
                .eq('is_active', true);
            if (error) throw error;
            return data || [];
        },
    });

    const { data: allAccounts } = useQuery({
        queryKey: ['accounts-all-active'],
        queryFn: async () => {
            const { data, error } = await supabase
                .from('accounts')
                .select('id, name, code, account_type')
                .eq('is_active', true)
                .order('name');
            if (error) throw error;
            return data || [];
        },
    });

    const { data: parties } = useQuery({
        queryKey: ['parties-active'],
        queryFn: async () => {
            const { data, error } = await supabase
                .from('parties')
                .select('id, name, type')
                .eq('is_active', true)
                .order('name');
            if (error) throw error;
            return data || [];
        },
    });

    const { data: fuelTypes } = useQuery({
        queryKey: ['fuel-types-active'],
        queryFn: async () => {
            const { data, error } = await supabase
                .from('fuel_types')
                .select('id, name, unit')
                .eq('is_active', true)
                .order('name');
            if (error) throw error;
            return data || [];
        },
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
                .in('voucher_type', [
                    'sale',
                    'purchase',
                    'adjustment',
                    'receipt',
                    'payment',
                    'opening',
                    'expense',
                    'shrinkage',
                    'asset',
                    'withdrawal',
                    'contra',
                ] as any[])
                .order('created_at', { ascending: false })
                .limit(30);

            if (error) throw error;

            const unique: any[] = [];
            const seen = new Set<string>();
            for (const item of data || []) {
                if (!seen.has(item.voucher_no)) {
                    unique.push(item);
                    seen.add(item.voucher_no);
                }
            }
            return unique.slice(0, 15);
        },
    });

    const mutation = useMutation({
        mutationFn: async (payload: FormState) => {

            if (txnType === 'SALE') {
                if (!payload.party_id || !payload.fuel_type_id || !payload.quantity || !payload.rate) {
                    const missing = [];
                    if (!payload.party_id) missing.push('Customer');
                    if (!payload.fuel_type_id) missing.push('Fuel Type');
                    if (!payload.quantity) missing.push('Quantity');
                    if (!payload.rate) missing.push('Rate');
                    throw new Error(`Customer, Fuel Type, Quantity, and Rate are required. Missing: ${missing.join(', ')}`);
                }

                const qty = numericOrZero(payload.quantity);
                const rate = numericOrZero(payload.rate);
                const total = qty * rate;

                if (qty <= 0 || rate <= 0 || total <= 0) {
                    throw new Error('Quantity and rate must be greater than zero.');
                }

                const rpcName = isEditMode ? 'edit_sale_transaction' : 'post_sale_transaction';
                const rpcPayload = isEditMode
                    ? {
                          p_original_voucher_no: editVoucherNo,
                          p_sale_date: payload.date,
                          p_party_id: payload.party_id,
                          p_fuel_type_id: payload.fuel_type_id,
                          p_quantity: qty,
                          p_rate_per_unit: rate,
                          p_total_amount: total,
                          p_is_credit: payload.is_credit,
                          p_notes: payload.narration,
                      }
                    : {
                          p_sale_date: payload.date,
                          p_party_id: payload.party_id,
                          p_fuel_type_id: payload.fuel_type_id,
                          p_quantity: qty,
                          p_rate_per_unit: rate,
                          p_total_amount: total,
                          p_is_credit: payload.is_credit,
                          p_notes: payload.narration,
                      };

                const { data, error } = await (supabase as any).rpc(rpcName, rpcPayload);
                const result = assertRpcSuccess(data, error, 'Sale transaction failed.');
                // NOTE: repair_inventory_from_transactions() removed — trg_sale_ledger_strict
                // handles delta-based stock correctly on UPDATE. Calling repair would
                // overwrite trigger-managed stock with a wrong recalculated value.
                return result;
            }

            if (txnType === 'PURCHASE') {
                if (!payload.party_id || !payload.fuel_type_id || !payload.quantity || !payload.rate) {
                    const missing = [];
                    if (!payload.party_id) missing.push('Supplier');
                    if (!payload.fuel_type_id) missing.push('Fuel Type');
                    if (!payload.quantity) missing.push('Quantity');
                    if (!payload.rate) missing.push('Rate');
                    throw new Error(`Supplier, Fuel Type, Quantity, and Rate are required. Missing: ${missing.join(', ')}`);
                }

                const qty = numericOrZero(payload.quantity);
                const rate = numericOrZero(payload.rate);
                const total = qty * rate;

                if (qty <= 0 || rate <= 0 || total <= 0) {
                    throw new Error('Quantity and rate must be greater than zero.');
                }

                const rpcName = isEditMode ? 'edit_purchase_transaction' : 'post_purchase_transaction';
                const rpcPayload = isEditMode
                    ? {
                          p_original_voucher_no: editVoucherNo,
                          p_purchase_date: payload.date,
                          p_party_id: payload.party_id,
                          p_fuel_type_id: payload.fuel_type_id,
                          p_quantity: qty,
                          p_rate_per_unit: rate,
                          p_total_amount: total,
                          p_is_paid_now: payload.is_paid_now,
                          p_payment_method: payload.payment_method,
                          p_notes: payload.narration,
                      }
                    : {
                          p_purchase_date: payload.date,
                          p_party_id: payload.party_id,
                          p_fuel_type_id: payload.fuel_type_id,
                          p_quantity: qty,
                          p_rate_per_unit: rate,
                          p_total_amount: total,
                          p_is_paid_now: payload.is_paid_now,
                          p_payment_method: payload.payment_method,
                          p_notes: payload.narration,
                      };

                // Block removed: upsert_purchase_transaction is unreachable and handled by edit_purchase_transaction

                const { data, error } = await (supabase as any).rpc(rpcName, rpcPayload);
                const result = assertRpcSuccess(data, error, 'Purchase transaction failed.');
                // Debug agent log fetch removed
                // NOTE: repair_inventory_from_transactions() removed — trg_purchase_ledger_strict
                // handles delta-based stock correctly on UPDATE. Calling repair would
                // overwrite trigger-managed stock ignoring shrinkage/opening-balance entries.
                return result;
            }

            if (txnType === 'ACTION_CENTER') {
                if (!payload.from_entity_id || !payload.to_entity_id || !payload.amount) {
                    throw new Error('Source, Destination, and Amount are required.');
                }

                const amount = numericOrZero(payload.amount);
                if (amount <= 0) {
                    throw new Error('Amount must be greater than zero.');
                }

                let vNo = editVoucherNo;

                if (isEditMode) {
                    if (!vNo) throw new Error('No voucher selected for edit.');

                    const { data: reverseData, error: reverseError } = await (supabase as any).rpc(
                        'reverse_transaction_safely',
                        { p_voucher_no: vNo }
                    );
                    assertRpcSuccess(reverseData, reverseError, 'Could not reverse old transaction.');
                } else {
                    const { data: generatedVoucher, error: voucherError } = await supabase.rpc('generate_voucher_no', {
                        prefix: 'VCH',
                    });
                    if (voucherError) throw voucherError;
                    vNo = generatedVoucher;
                }

                const { data, error } = await (supabase as any).rpc('create_manage_transaction', {
                    p_voucher_no: vNo,
                    p_transaction_type: payload.action_type,
                    p_from_type: payload.from_type,
                    p_from_entity_id: payload.from_entity_id,
                    p_to_type: payload.to_type,
                    p_to_entity_id: payload.to_entity_id,
                    p_amount: amount,
                    p_narration: payload.narration,
                    p_transaction_date: payload.date,
                });

                return assertRpcSuccess(data, error, 'Movement transaction failed.');
            }

            if (txnType === 'SHRINKAGE') {
                if (!payload.fuel_type_id || !payload.quantity_lost || !payload.rate_per_liter) {
                    throw new Error('Please provide Fuel Type, Quantity and Rate.');
                }

                const quantityLost = numericOrZero(payload.quantity_lost);
                const ratePerLiter = numericOrZero(payload.rate_per_liter);

                if (quantityLost <= 0 || ratePerLiter <= 0) {
                    throw new Error('Quantity lost and rate must be greater than zero.');
                }

                const { data, error } = await (supabase as any).rpc('post_fuel_shrinkage_writeoff', {
                    p_fuel_type_id: payload.fuel_type_id,
                    p_quantity_lost: quantityLost,
                    p_rate_per_liter: ratePerLiter,
                    p_date: payload.date,
                    p_reason: payload.reason,
                    p_voucher_no: isEditMode ? editVoucherNo : null,
                });

                return assertRpcSuccess(data, error, 'Shrinkage transaction failed.');
            }

            if (txnType === 'EXPENSE') {
                if (!payload.expense_account_id || !payload.payment_account_id || !payload.amount) {
                    throw new Error('Missing required fields.');
                }

                const amount = numericOrZero(payload.amount);
                if (amount <= 0) {
                    throw new Error('Amount must be greater than zero.');
                }

                const { data, error } = await (supabase as any).rpc('post_expense_entry', {
                    p_expense_account_id: payload.expense_account_id,
                    p_payment_account_id: payload.payment_account_id,
                    p_amount: amount,
                    p_narration: payload.narration,
                    p_date: payload.date,
                    p_voucher_no: isEditMode ? editVoucherNo : null,
                });

                return assertRpcSuccess(data, error, 'Expense transaction failed.');
            }

            if (txnType === 'ASSET_PURCHASE') {
                if (!payload.asset_name || !payload.amount || !payload.payment_account_id) {
                    throw new Error('Missing asset details or payment source.');
                }

                const amount = numericOrZero(payload.amount);
                if (amount <= 0) {
                    throw new Error('Amount must be greater than zero.');
                }

                const { data, error } = await (supabase as any).rpc('purchase_fixed_asset', {
                    p_name: payload.asset_name,
                    p_category: payload.asset_category,
                    p_amount: amount,
                    p_date: payload.date,
                    p_paid_from_account_id: payload.payment_account_id,
                    p_description: payload.narration,
                    p_voucher_no: isEditMode ? editVoucherNo : null,
                });

                return assertRpcSuccess(data, error, 'Asset purchase transaction failed.');
            }

            if (txnType === 'OWNER_WITHDRAWAL') {
                if (!payload.amount || !payload.payment_account_id) {
                    throw new Error('Amount and payment source required.');
                }

                const amount = numericOrZero(payload.amount);
                if (amount <= 0) {
                    throw new Error('Amount must be greater than zero.');
                }

                const { data, error } = await (supabase as any).rpc('post_owner_withdrawal', {
                    p_payment_account_id: payload.payment_account_id,
                    p_amount: amount,
                    p_narration: payload.narration || 'Owner Withdrawal',
                    p_date: payload.date,
                    p_voucher_no: isEditMode ? editVoucherNo : null,
                });

                return assertRpcSuccess(data, error, 'Owner withdrawal transaction failed.');
            }

            throw new Error('Unsupported transaction type.');
        },
        onSuccess: async (data, variables) => {
            const voucherNo = (data as { voucher_no?: string })?.voucher_no;
            toast({
                title: isEditMode ? 'Transaction Updated' : 'Transaction Posted',
                description: isEditMode
                    ? 'The voucher was safely reversed and re-posted.'
                    : voucherNo
                      ? `Committed as ${voucherNo}. Ledger and inventory updated.`
                      : 'The record has been committed to the ledger and inventory.',
            });

            await invalidateTransactionQueries();

            resetForm(variables.date);

            if (isEditMode) {
                navigate(-1);
            }
        },
        onError: (e: Error) => {
            toast({ variant: 'destructive', title: 'Transaction Failed', description: e.message });
        },
    });

    const deleteMutation = useMutation({
        mutationFn: async () => {
            if (!editVoucherNo) throw new Error('No voucher selected for deletion.');
            const { data, error } = await supabase.rpc('delete_transaction_safely', {
                p_voucher_no: editVoucherNo,
            });
            return assertRpcSuccess(data, error, 'Delete failed.');
        },
        onSuccess: async () => {
            toast({ title: 'Transaction Deleted', description: `Voucher ${editVoucherNo} was safely deleted.` });
            await invalidateTransactionQueries();
            clearEditMode();
        },
        onError: (e: Error) => {
            toast({ variant: 'destructive', title: 'Delete Failed', description: e.message });
        },
    });

    const handleTypeChange = (val: TransactionType) => {
        setTxnType(val);
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
            rate: '',
        }));
    };

    const isBusy = mutation.isPending || deleteMutation.isPending;

    const tabs: Array<{ id: TransactionType; label: string; icon: any; color: string }> = [
        { id: 'SALE', label: 'Fuel Sale', icon: TrendingUp, color: 'emerald' },
        { id: 'PURCHASE', label: 'Fuel Purchase', icon: TrendingDown, color: 'rose' },
        { id: 'ACTION_CENTER', label: 'Party Transfer', icon: Users, color: 'emerald' },
        { id: 'EXPENSE', label: 'Standard Expense', icon: Wallet, color: 'slate' },
        { id: 'SHRINKAGE', label: 'Fuel Loss', icon: AlertTriangle, color: 'rose' },
        { id: 'ASSET_PURCHASE', label: 'Asset Entry', icon: Building, color: 'blue' },
        { id: 'OWNER_WITHDRAWAL', label: 'Owner Out', icon: History, color: 'amber' },
    ];

    return (
        <DashboardLayout>
            <div className="max-w-7xl mx-auto pb-20 px-6">
                <div className="report-header mb-8 flex flex-wrap gap-4 justify-between items-end">
                    <div>
                        <h1 className="report-title">{isEditMode ? 'Modify Transaction' : 'Voucher Factory'}</h1>
                        <p className="report-subtitle">
                            {isEditMode
                                ? `Revising existing voucher ${editVoucherNo}`
                                : 'Unified terminal for processing administrative, operational, and inventory adjustments.'}
                        </p>
                    </div>

                </div>

                <div className="grid grid-cols-1 lg:grid-cols-12 gap-8">
                    <div className="lg:col-span-8">
                        <div className="border border-slate-300 bg-white">
                            <div className="bg-slate-900 px-6 py-6 border-b border-slate-800">
                                <div className="flex flex-wrap gap-2">
                                    {tabs.map(mode => {
                                        const Icon = mode.icon;
                                        const isActive = txnType === mode.id;
                                        return (
                                            <button
                                                key={mode.id}
                                                type="button"
                                                disabled={isBusy}
                                                onClick={() => handleTabChange(mode.id)}
                                                className={cn(
                                                    'flex items-center gap-3 px-4 py-2 text-[10px] font-black uppercase tracking-widest border transition-all disabled:opacity-50',
                                                    isActive
                                                        ? tabClassMap[mode.color]?.active
                                                        : 'bg-slate-800 border-slate-700 text-slate-400 hover:text-white hover:border-slate-500'
                                                )}
                                            >
                                                <Icon className={cn('h-4 w-4', isActive ? 'text-white' : 'text-slate-500')} />
                                                {mode.label}
                                            </button>
                                        );
                                    })}
                                </div>
                            </div>

                            <div className="p-8">
                                <form
                                    onSubmit={e => {
                                        e.preventDefault();
                                        mutation.mutate(form);
                                    }}
                                    className="space-y-8"
                                >
                                    <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
                                        <div className="space-y-2">
                                            <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest flex items-center gap-2">
                                                <Calendar className="h-3 w-3" /> Posting Date
                                            </Label>
                                            <Input
                                                type="date"
                                                value={form.date}
                                                disabled={isBusy}
                                                onChange={e => setForm(prev => ({ ...prev, date: e.target.value }))}
                                                className="h-11 rounded-none border-slate-300 font-bold"
                                            />
                                        </div>

                                        {txnType !== 'SHRINKAGE' &&
                                            txnType !== 'ACTION_CENTER' &&
                                            txnType !== 'SALE' &&
                                            txnType !== 'PURCHASE' && (
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest flex items-center gap-2">
                                                        <Wallet className="h-3 w-3" /> Payment Source (Cash/Bank)
                                                    </Label>
                                                    <Select
                                                        value={form.payment_account_id}
                                                        disabled={isBusy}
                                                        onValueChange={val => {
                                                            if (!val) return;
                                                            setForm(prev => ({ ...prev, payment_account_id: val }));
                                                        }}
                                                    >
                                                        <SelectTrigger className="h-11 rounded-none border-slate-300 font-bold focus:ring-0">
                                                            <SelectValue placeholder="Select Cash/Bank..." />
                                                        </SelectTrigger>
                                                        <SelectContent className="rounded-none border-slate-900">
                                                            {paymentAccounts?.map(a => (
                                                                <SelectItem key={a.id} value={a.id} className="font-bold text-xs uppercase">
                                                                    {a.name}
                                                                </SelectItem>
                                                            ))}
                                                        </SelectContent>
                                                    </Select>
                                                </div>
                                            )}

                                        {(txnType === 'SALE' || txnType === 'PURCHASE') && (
                                            <div className="space-y-2">
                                                <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest flex items-center gap-2">
                                                    <Users className="h-3 w-3" />{' '}
                                                    {txnType === 'SALE' ? 'Select Customer' : 'Select Supplier'}
                                                </Label>
                                                <Select
                                                    value={form.party_id}
                                                    disabled={isBusy}
                                                    onValueChange={val => {
                                                        if (!val) return;
                                                        setForm(prev => ({ ...prev, party_id: val }));
                                                    }}
                                                >
                                                    <SelectTrigger className="h-11 rounded-none border-slate-300 font-bold focus:ring-0">
                                                        <SelectValue
                                                            placeholder={`Search ${txnType === 'SALE' ? 'Customer' : 'Supplier'}...`}
                                                        />
                                                    </SelectTrigger>
                                                    <SelectContent className="rounded-none border-slate-900 max-h-[300px]">
                                                        {parties?.map(p => (
                                                            <SelectItem key={p.id} value={p.id} className="font-bold text-xs uppercase">
                                                                {p.name}
                                                            </SelectItem>
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

                                    <div
                                        className={cn(
                                            'p-6 border space-y-8 transition-all',
                                            txnType === 'ACTION_CENTER'
                                                ? 'bg-emerald-50 border-emerald-100'
                                                : txnType === 'SHRINKAGE'
                                                  ? 'bg-rose-50 border-rose-100'
                                                  : txnType === 'ASSET_PURCHASE'
                                                    ? 'bg-blue-50 border-blue-100'
                                                    : txnType === 'OWNER_WITHDRAWAL'
                                                      ? 'bg-amber-50 border-amber-100'
                                                      : 'bg-slate-50 border-slate-200'
                                        )}
                                    >
                                        {(txnType === 'SALE' || txnType === 'PURCHASE') && (
                                            <div className="space-y-8">
                                                <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">
                                                            Fuel Type
                                                        </Label>
                                                        <Select
                                                            value={form.fuel_type_id}
                                                            disabled={isBusy}
                                                            onValueChange={val => {
                                                            if (!val) return;
                                                            setForm(prev => ({ ...prev, fuel_type_id: val }));
                                                        }}
                                                        >
                                                            <SelectTrigger className="h-11 rounded-none border-slate-300 bg-white font-bold focus:ring-0">
                                                                <SelectValue placeholder="Select Fuel..." />
                                                            </SelectTrigger>
                                                            <SelectContent className="rounded-none border-slate-900">
                                                                {fuelTypes?.map(f => (
                                                                    <SelectItem key={f.id} value={f.id} className="font-bold text-xs uppercase">
                                                                        {f.name}
                                                                    </SelectItem>
                                                                ))}
                                                            </SelectContent>
                                                        </Select>
                                                    </div>

                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">
                                                            Quantity ({fuelTypes?.find(f => f.id === form.fuel_type_id)?.unit || 'Ltrs'})
                                                        </Label>
                                                        <Input
                                                            className="h-11 rounded-none text-xl font-black num-audit border-slate-300 bg-white focus:ring-0"
                                                            placeholder="0.00"
                                                            type="number"
                                                            min="0"
                                                            step="any"
                                                            disabled={isBusy}
                                                            value={form.quantity}
                                                            onChange={e => setForm(prev => ({ ...prev, quantity: e.target.value }))}
                                                        />
                                                    </div>

                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">
                                                            Rate per Unit
                                                        </Label>
                                                        <div className="relative">
                                                            <span className="absolute left-4 top-1/2 -translate-y-1/2 font-bold text-slate-400 text-xs">
                                                                Rs.
                                                            </span>
                                                            <Input
                                                                className="h-11 rounded-none pl-10 text-xl font-black num-audit border-slate-300 bg-white focus:ring-0"
                                                                placeholder="0.00"
                                                                type="number"
                                                                min="0"
                                                                step="any"
                                                                disabled={isBusy}
                                                                value={form.rate}
                                                                onChange={e => setForm(prev => ({ ...prev, rate: e.target.value }))}
                                                            />
                                                        </div>
                                                    </div>
                                                </div>

                                                <div className="flex flex-wrap items-center justify-between gap-4 p-4 bg-white border border-slate-200">
                                                    <div className="flex flex-col">
                                                        <span className="text-[10px] font-black uppercase text-slate-400">Estimated Total</span>
                                                        <span className="text-2xl font-black text-slate-900 num-audit">
                                                            {formatPKR(numericOrZero(form.quantity) * numericOrZero(form.rate))}
                                                        </span>
                                                    </div>
                                                </div>
                                            </div>
                                        )}

                                        {txnType === 'ACTION_CENTER' && (
                                            <div className="space-y-8">
                                                <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
                                                    <div className="space-y-2 md:col-span-2">
                                                        <Label className="text-[10px] uppercase font-black text-emerald-600 tracking-widest">
                                                            Amount to Move (PKR)
                                                        </Label>
                                                        <div className="relative">
                                                            <span className="absolute left-4 top-1/2 -translate-y-1/2 font-black text-emerald-400 text-lg">
                                                                Rs.
                                                            </span>
                                                            <Input
                                                                className="h-14 rounded-none pl-12 text-3xl font-black num-audit border-emerald-300 bg-white text-emerald-900 focus:ring-0 shadow-sm"
                                                                placeholder="0.00"
                                                                type="number"
                                                                min="0"
                                                                step="any"
                                                                disabled={isBusy}
                                                                value={form.amount}
                                                                onChange={e => setForm(prev => ({ ...prev, amount: e.target.value }))}
                                                            />
                                                        </div>
                                                    </div>
                                                </div>

                                                <div className="grid grid-cols-1 md:grid-cols-2 gap-12 pt-4">
                                                    <div className="space-y-4">
                                                        <div className="flex justify-between items-center border-b border-emerald-200 pb-2">
                                                            <div className="flex items-center gap-2">
                                                                <TrendingDown className="h-3 w-3 text-rose-500" />
                                                                <Label className="text-[10px] uppercase font-black text-emerald-600 tracking-widest">
                                                                    SENDER (Paisa Nikla)
                                                                </Label>
                                                            </div>
                                                        </div>
                                                        <Select
                                                            value={form.from_entity_id}
                                                            disabled={isBusy}
                                                            onValueChange={val => {
                                                                if (!val) return;
                                                                const isParty = parties?.some(p => p.id === val);
                                                                setForm(prev => ({ ...prev, from_entity_id: val, from_type: isParty ? 'party' : 'account' }));
                                                            }}
                                                        >
                                                            <SelectTrigger className="h-12 rounded-none border-emerald-300 bg-white font-black text-xs uppercase text-emerald-900 shadow-sm">
                                                                <SelectValue placeholder="Select Sender (Who paid?)" />
                                                            </SelectTrigger>
                                                            <SelectContent className="max-h-[300px] rounded-none border-emerald-900">
                                                                <div className="p-2 bg-slate-100 text-[9px] font-bold text-slate-500 uppercase tracking-widest">
                                                                    Parties / Customers / Suppliers
                                                                </div>
                                                                {parties?.map(p => (
                                                                    <SelectItem key={p.id} value={p.id} className="font-bold text-xs uppercase py-3 border-b border-slate-50 last:border-0">
                                                                        <Users className="h-3 w-3 inline mr-2 text-slate-400" /> {p.name}
                                                                    </SelectItem>
                                                                ))}
                                                                <div className="p-2 bg-slate-100 text-[9px] font-bold text-slate-500 uppercase tracking-widest">
                                                                    Cash / Bank / Assets
                                                                </div>
                                                                {allAccounts
                                                                    ?.filter(a => ['asset', 'bank', 'cash'].includes(a.account_type))
                                                                    .map(a => (
                                                                        <SelectItem key={a.id} value={a.id} className="font-bold text-xs uppercase py-3 border-b border-slate-50 last:border-0">
                                                                            <Building className="h-3 w-3 inline mr-2 text-slate-400" /> {a.name}
                                                                        </SelectItem>
                                                                    ))}
                                                            </SelectContent>
                                                        </Select>
                                                    </div>

                                                    <div className="space-y-4">
                                                        <div className="flex justify-between items-center border-b border-emerald-200 pb-2">
                                                            <div className="flex items-center gap-2">
                                                                <TrendingUp className="h-3 w-3 text-emerald-500" />
                                                                <Label className="text-[10px] uppercase font-black text-emerald-600 tracking-widest">
                                                                    RECEIVER (Paisa Aya)
                                                                </Label>
                                                            </div>
                                                        </div>
                                                        <Select
                                                            value={form.to_entity_id}
                                                            disabled={isBusy}
                                                            onValueChange={val => {
                                                                if (!val) return;
                                                                const isParty = parties?.some(p => p.id === val);
                                                                setForm(prev => ({ ...prev, to_entity_id: val, to_type: isParty ? 'party' : 'account' }));
                                                            }}
                                                        >
                                                            <SelectTrigger className="h-12 rounded-none border-emerald-300 bg-white font-black text-xs uppercase text-emerald-900 shadow-sm">
                                                                <SelectValue placeholder="Select Receiver (Who got paid?)" />
                                                            </SelectTrigger>
                                                            <SelectContent className="max-h-[300px] rounded-none border-emerald-900">
                                                                <div className="p-2 bg-slate-100 text-[9px] font-bold text-slate-500 uppercase tracking-widest">
                                                                    Parties / Customers / Suppliers
                                                                </div>
                                                                {parties?.map(p => (
                                                                    <SelectItem key={p.id} value={p.id} className="font-bold text-xs uppercase py-3 border-b border-slate-50 last:border-0">
                                                                        <Users className="h-3 w-3 inline mr-2 text-slate-400" /> {p.name}
                                                                    </SelectItem>
                                                                ))}
                                                                <div className="p-2 bg-slate-100 text-[9px] font-bold text-slate-500 uppercase tracking-widest">
                                                                    Cash / Bank / Assets
                                                                </div>
                                                                {allAccounts
                                                                    ?.filter(a => ['asset', 'bank', 'cash'].includes(a.account_type))
                                                                    .map(a => (
                                                                        <SelectItem key={a.id} value={a.id} className="font-bold text-xs uppercase py-3 border-b border-slate-50 last:border-0">
                                                                            <Building className="h-3 w-3 inline mr-2 text-slate-400" /> {a.name}
                                                                        </SelectItem>
                                                                    ))}
                                                            </SelectContent>
                                                        </Select>
                                                    </div>
                                                </div>
                                            </div>
                                        )}

                                        {txnType === 'EXPENSE' && (
                                            <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
                                                <div className="space-y-2">
                                                    <div className="flex justify-between items-center">
                                                        <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">
                                                            Expense Classification
                                                        </Label>
                                                        <button
                                                            type="button"
                                                            disabled={isBusy}
                                                            onClick={() => setIsAddModalOpen(true)}
                                                            className="text-[9px] font-black text-slate-400 hover:text-slate-900 flex items-center gap-1 uppercase disabled:opacity-50"
                                                        >
                                                            <PlusCircle className="h-2.5 w-2.5" /> Add New
                                                        </button>
                                                    </div>
                                                    <Select
                                                        value={form.expense_account_id}
                                                        disabled={isBusy}
                                                        onValueChange={val => {
                                                        if (!val) return;
                                                        setForm(prev => ({ ...prev, expense_account_id: val }));
                                                    }}
                                                    >
                                                        <SelectTrigger className="h-11 rounded-none border-slate-300 bg-white font-bold focus:ring-0">
                                                            <SelectValue placeholder="Select Category..." />
                                                        </SelectTrigger>
                                                        <SelectContent className="rounded-none border-slate-900">
                                                            {expenseAccounts?.map(a => (
                                                                <SelectItem key={a.id} value={a.id} className="font-bold text-xs uppercase">
                                                                    {a.name}
                                                                </SelectItem>
                                                            ))}
                                                        </SelectContent>
                                                    </Select>
                                                </div>
                                                <div className="space-y-2">
                                                    <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">
                                                        Amount (PKR)
                                                    </Label>
                                                    <div className="relative">
                                                        <span className="absolute left-4 top-1/2 -translate-y-1/2 font-bold text-slate-400">
                                                            Rs.
                                                        </span>
                                                        <Input
                                                            className="h-11 rounded-none pl-12 text-xl font-black num-audit border-slate-300 focus:ring-0 focus:border-slate-900"
                                                            placeholder="0.00"
                                                            type="number"
                                                            min="0"
                                                            step="any"
                                                            disabled={isBusy}
                                                            value={form.amount}
                                                            onChange={e => setForm(prev => ({ ...prev, amount: e.target.value }))}
                                                        />
                                                    </div>
                                                </div>
                                            </div>
                                        )}

                                        {txnType === 'SHRINKAGE' && (
                                            <>
                                                <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-rose-600 tracking-widest">
                                                            Select Product
                                                        </Label>
                                                        <Select
                                                            value={form.fuel_type_id}
                                                            disabled={isBusy}
                                                            onValueChange={val => {
                                                            if (!val) return;
                                                            setForm(prev => ({ ...prev, fuel_type_id: val }));
                                                        }}
                                                        >
                                                            <SelectTrigger className="h-11 rounded-none border-rose-300 bg-white font-bold text-rose-900 focus:ring-0">
                                                                <SelectValue placeholder="Fuel Type..." />
                                                            </SelectTrigger>
                                                            <SelectContent className="rounded-none border-slate-900">
                                                                {fuelTypes?.map(f => (
                                                                    <SelectItem key={f.id} value={f.id} className="font-bold text-xs uppercase">
                                                                        {f.name}
                                                                    </SelectItem>
                                                                ))}
                                                            </SelectContent>
                                                        </Select>
                                                    </div>
                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-rose-600 tracking-widest">
                                                            Qty Lost (Liters)
                                                        </Label>
                                                        <div className="relative">
                                                            <Input
                                                                className="h-11 rounded-none pr-12 text-xl font-black num-audit border-rose-300 bg-white text-rose-900 focus:ring-0"
                                                                placeholder="0.00"
                                                                type="number"
                                                                min="0"
                                                                step="any"
                                                                disabled={isBusy}
                                                                value={form.quantity_lost}
                                                                onChange={e => setForm(prev => ({ ...prev, quantity_lost: e.target.value }))}
                                                            />
                                                            <span className="absolute right-4 top-1/2 -translate-y-1/2 font-bold text-rose-300 text-xs uppercase">
                                                                Ltrs
                                                            </span>
                                                        </div>
                                                    </div>
                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-rose-600 tracking-widest">
                                                            Avg Rate/Liter
                                                        </Label>
                                                        <div className="relative">
                                                            <span className="absolute left-4 top-1/2 -translate-y-1/2 font-bold text-rose-300 text-xs">
                                                                Rs.
                                                            </span>
                                                            <Input
                                                                className="h-11 rounded-none pl-10 text-xl font-black num-audit border-rose-300 bg-white text-rose-900 focus:ring-0"
                                                                placeholder="0.00"
                                                                type="number"
                                                                min="0"
                                                                step="any"
                                                                disabled={isBusy}
                                                                value={form.rate_per_liter}
                                                                onChange={e => setForm(prev => ({ ...prev, rate_per_liter: e.target.value }))}
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

                                        {txnType === 'ASSET_PURCHASE' && (
                                            <div className="space-y-8">
                                                <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-blue-600 tracking-widest">
                                                            Asset Name / Title
                                                        </Label>
                                                        <Input
                                                            className="h-11 rounded-none border-blue-300 focus:border-blue-600 font-bold text-blue-900 bg-white"
                                                            placeholder="e.g. Perkins 50kVA Generator"
                                                            disabled={isBusy}
                                                            value={form.asset_name}
                                                            onChange={e => setForm(prev => ({ ...prev, asset_name: e.target.value }))}
                                                        />
                                                    </div>
                                                    <div className="space-y-2">
                                                        <Label className="text-[10px] uppercase font-black text-blue-600 tracking-widest">
                                                            Asset Category
                                                        </Label>
                                                        <Select
                                                            value={form.asset_category}
                                                            disabled={isBusy}
                                                            onValueChange={val => {
                                                            if (!val) return;
                                                            setForm(prev => ({ ...prev, asset_category: val }));
                                                        }}
                                                        >
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
                                                    <Label className="text-[10px] uppercase font-black text-blue-600 tracking-widest">
                                                        Purchase Amount (PKR)
                                                    </Label>
                                                    <div className="relative">
                                                        <span className="absolute left-4 top-1/2 -translate-y-1/2 font-bold text-blue-300">
                                                            Rs.
                                                        </span>
                                                        <Input
                                                            className="h-11 rounded-none pl-12 text-xl font-black num-audit border-blue-300 focus:border-blue-600 focus:ring-0 text-blue-900 bg-white"
                                                            placeholder="0.00"
                                                            type="number"
                                                            min="0"
                                                            step="any"
                                                            disabled={isBusy}
                                                            value={form.amount}
                                                            onChange={e => setForm(prev => ({ ...prev, amount: e.target.value }))}
                                                        />
                                                    </div>
                                                </div>
                                            </div>
                                        )}

                                        {txnType === 'OWNER_WITHDRAWAL' && (
                                            <div className="space-y-2">
                                                <Label className="text-[10px] uppercase font-black text-amber-600 tracking-widest">
                                                    Withdrawal Amount (PKR)
                                                </Label>
                                                <div className="relative">
                                                    <span className="absolute left-4 top-1/2 -translate-y-1/2 font-bold text-amber-300">
                                                        Rs.
                                                    </span>
                                                    <Input
                                                        className="h-11 rounded-none pl-12 text-xl font-black num-audit border-amber-300 focus:border-amber-600 focus:ring-0 text-amber-900 bg-white"
                                                        placeholder="0.00"
                                                        type="number"
                                                        min="0"
                                                        step="any"
                                                        disabled={isBusy}
                                                        value={form.amount}
                                                        onChange={e => setForm(prev => ({ ...prev, amount: e.target.value }))}
                                                    />
                                                </div>
                                            </div>
                                        )}

                                        <div className="space-y-2 pt-4 border-t border-slate-200">
                                            <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest flex items-center gap-2">
                                                <PenTool className="h-3 w-3" /> Narration / Ledger Memo
                                            </Label>
                                            <Input
                                                className="h-11 rounded-none bg-white font-bold border-slate-300 placeholder:font-medium placeholder:italic text-slate-900"
                                                placeholder={
                                                    txnType === 'SHRINKAGE'
                                                        ? 'Brief reason for stock write-off...'
                                                        : txnType === 'ASSET_PURCHASE'
                                                          ? 'Describe vendor, warranty, or condition...'
                                                          : 'Enter brief description of this transaction...'
                                                }
                                                disabled={isBusy}
                                                value={txnType === 'SHRINKAGE' ? form.reason : form.narration}
                                                onChange={e => {
                                                    if (txnType === 'SHRINKAGE') setForm(prev => ({ ...prev, reason: e.target.value }));
                                                    else setForm(prev => ({ ...prev, narration: e.target.value }));
                                                }}
                                            />
                                        </div>
                                    </div>

                                    <div className="flex flex-col gap-4">
                                        <Button
                                            type="submit"
                                            className={cn(
                                                'h-12 w-full text-white font-black text-xs uppercase tracking-[0.2em] rounded-none shadow-sm transition-all',
                                                txnType === 'ACTION_CENTER'
                                                    ? 'bg-emerald-600 hover:bg-emerald-700'
                                                    : txnType === 'EXPENSE'
                                                    ? 'bg-slate-900 hover:bg-black'
                                                    : txnType === 'SHRINKAGE'
                                                        ? 'bg-rose-600 hover:bg-rose-700'
                                                        : txnType === 'ASSET_PURCHASE'
                                                        ? 'bg-blue-600 hover:bg-blue-700'
                                                        : 'bg-amber-600 hover:bg-amber-700'
                                            )}
                                            disabled={isBusy}
                                        >
                                            {mutation.isPending ? (
                                                <Loader2 className="animate-spin h-5 w-5 mr-2" />
                                            ) : (
                                                <CheckCircle2 className="h-4 w-4 mr-2" />
                                            )}
                                            {mutation.isPending
                                                ? 'PROCESSING...'
                                                : txnType === 'ACTION_CENTER'
                                                ? 'COMMIT MOVEMENT'
                                                : isEditMode
                                                    ? 'UPDATE TRANSACTION'
                                                    : 'FINALIZE TRANSACTION'}
                                        </Button>

                                        {isEditMode && (
                                            <div className="grid grid-cols-2 gap-4">
                                                <Button
                                                    type="button"
                                                    variant="outline"
                                                    className="h-12 font-black text-xs uppercase tracking-[0.2em] rounded-none border-slate-300 hover:bg-slate-50"
                                                    disabled={isBusy}
                                                    onClick={clearEditMode}
                                                >
                                                    CANCEL EDIT
                                                </Button>
                                                <Button
                                                    type="button"
                                                    variant="destructive"
                                                    className="h-12 font-black text-xs uppercase tracking-[0.2em] rounded-none"
                                                    disabled={isBusy}
                                                    onClick={() => deleteMutation.mutate()}
                                                >
                                                    {deleteMutation.isPending ? <Loader2 className="animate-spin h-4 w-4 mr-2" /> : 'DELETE VOUCHER'}
                                                </Button>
                                            </div>
                                        )}
                                    </div>
                                </form>
                            </div>
                        </div>
                    </div>

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
                                            const isAction = ['adjustment', 'receipt', 'payment', 'contra'].includes(v.voucher_type);
                                            const isWithdrawal = v.voucher_type === 'withdrawal';
                                            const amount = v.debit_amount || v.credit_amount || 0;
                                            const name = v.party?.name || v.accounts?.name || 'General Entry';

                                            return (
                                                <div
                                                    key={v.voucher_no}
                                                    className="p-5 hover:bg-slate-50 transition-colors group border-b border-slate-100 last:border-0 cursor-pointer"
                                                    onClick={() => {
                                                        if (isBusy) return;
                                                        if (v.voucher_type === 'sale' || v.voucher_type === 'purchase') {
                                                            navigate(`/manage-transactions?edit=${v.voucher_no}&type=${v.voucher_type.toUpperCase()}`);
                                                        } else {
                                                            toast({ title: 'Edit unsupported', description: 'Can only edit sales and purchases for now.' });
                                                        }
                                                    }}
                                                >
                                                    <div className="flex justify-between items-start mb-2">
                                                        <div className="flex items-center gap-2">
                                                            <span
                                                                className={cn(
                                                                    'text-[9px] font-mono font-black border px-2 py-0.5 rounded-none',
                                                                    isAction
                                                                        ? 'bg-emerald-50 border-emerald-200 text-emerald-600'
                                                                        : isShrinkage
                                                                          ? 'bg-rose-50 border-rose-200 text-rose-600'
                                                                          : isAsset
                                                                            ? 'bg-blue-50 border-blue-200 text-blue-600'
                                                                            : isWithdrawal
                                                                              ? 'bg-amber-50 border-amber-200 text-amber-600'
                                                                              : 'bg-slate-100 border-slate-200 text-slate-500'
                                                                )}
                                                            >
                                                                {v.voucher_no}
                                                            </span>
                                                        </div>
                                                        <span className="text-[9px] font-black text-slate-400 uppercase tracking-widest">
                                                            {v.posting_date}
                                                        </span>
                                                    </div>
                                                    <div className="flex justify-between items-center">
                                                        <div className="flex-1 min-w-0 pr-4">
                                                            {isAction ? (
                                                                <p className="text-[11px] font-black text-emerald-700 uppercase leading-none mb-1 truncate flex items-center gap-1">
                                                                    {v.accounts?.name || 'Party'} <ArrowRight className="h-2 w-2" /> {name}
                                                                </p>
                                                            ) : (
                                                                <p className="text-[11px] font-black text-slate-800 uppercase leading-none mb-1 truncate">
                                                                    {name}
                                                                </p>
                                                            )}
                                                            <p className="text-[10px] text-slate-400 line-clamp-1 italic font-medium">
                                                                {v.narration}
                                                            </p>
                                                        </div>
                                                        <div className="text-right">
                                                            <span
                                                                className={cn(
                                                                    'text-sm font-black num-audit tracking-tight',
                                                                    isShrinkage
                                                                        ? 'text-rose-600'
                                                                        : isAction
                                                                          ? 'text-emerald-700'
                                                                          : 'text-slate-900'
                                                                )}
                                                            >
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

                        <div className="border border-slate-900 p-6 bg-slate-900 text-white">
                            <h4 className="text-[11px] font-black uppercase tracking-widest mb-3 border-b border-white/20 pb-2">
                                Factory Governance
                            </h4>
                            <div className="space-y-4">
                                <div className="flex items-start gap-3">
                                    <div className="h-4 w-4 rounded-full bg-emerald-500 shrink-0 mt-0.5" />
                                    <p className="text-[9px] text-slate-300 font-bold uppercase leading-relaxed">
                                        All transactions recorded here are posted through database RPCs to protect ledger and inventory integrity.
                                    </p>
                                </div>
                                <div className="flex items-start gap-3">
                                    <div className="h-4 w-4 rounded-full bg-rose-500 shrink-0 mt-0.5" />
                                    <p className="text-[9px] text-slate-300 font-bold uppercase leading-relaxed">
                                        Edit/delete operations must reverse the old voucher instead of directly updating or deleting ledger rows.
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
                onSuccess={id => {
                    setForm(prev => ({ ...prev, expense_account_id: id }));
                    queryClient.invalidateQueries({ queryKey: ['accounts-expense'] });
                    queryClient.invalidateQueries({ queryKey: ['accounts-all-active'] });
                }}
            />
        </DashboardLayout>
    );
}
