
import { useState, useEffect } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useToast } from '@/hooks/use-toast';
import {
    Dialog,
    DialogContent,
    DialogHeader,
    DialogTitle,
    DialogFooter,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Loader2, Edit3 } from 'lucide-react';

interface EditVoucherProps {
    isOpen: boolean;
    onClose: () => void;
    voucher: {
        voucher_no: string;
        type: string;
        party_name: string;
        narration: string;
        debit: number;
        credit: number;
    } | null;
}

export function V11EditVoucher({ isOpen, onClose, voucher }: EditVoucherProps) {
    const { toast } = useToast();
    const queryClient = useQueryClient();
    const [amount, setAmount] = useState('');
    const [narration, setNarration] = useState('');

    useEffect(() => {
        if (voucher) {
            setAmount(String(Math.max(voucher.debit, voucher.credit)));
            setNarration(voucher.narration);
        }
    }, [voucher]);

    const mutation = useMutation({
        mutationFn: async () => {
            if (!voucher) return;

            let table = 'ledger_entries';
            let updateData: any = { narration };

            // For Sales/Purchases/Payments, we edit the source table so triggers update stock/ledgers
            if (voucher.type === 'sale') {
                const { data } = await supabase.from('sales').select('quantity').eq('voucher_no', voucher.voucher_no).single();
                const newAmount = parseFloat(amount);
                const newRate = data?.quantity ? newAmount / data.quantity : 0;

                const { error } = await supabase.from('sales').update({
                    total_amount: newAmount,
                    rate_per_unit: newRate,
                    notes: narration
                }).eq('voucher_no', voucher.voucher_no);
                if (error) throw error;
            } else if (voucher.type === 'purchase') {
                const { data } = await supabase.from('purchases').select('quantity').eq('voucher_no', voucher.voucher_no).single();
                const newAmount = parseFloat(amount);
                const newRate = data?.quantity ? newAmount / data.quantity : 0;

                const { error } = await supabase.from('purchases').update({
                    total_amount: newAmount,
                    rate_per_unit: newRate,
                    notes: narration
                }).eq('voucher_no', voucher.voucher_no);
                if (error) throw error;
            } else if (voucher.type === 'receipt' || voucher.type === 'payment') {
                await supabase.from('payments').update({
                    amount: parseFloat(amount),
                    narration: narration
                }).eq('voucher_no', voucher.voucher_no);
            } else {
                // Direct Ledger Edit
                toast({ variant: 'destructive', title: 'Manual Edit Blocked', description: 'Journal entries must be reversed/re-entered for balance integrity.' });
                throw new Error('Direct ledger edit restricted.');
            }
        },
        onSuccess: () => {
            toast({ title: 'Voucher Revised', description: 'Changes committed and balances recalculated.' });
            queryClient.invalidateQueries({ queryKey: ['roznamcha'] });
            queryClient.invalidateQueries({ queryKey: ['transaction-history'] });
            queryClient.invalidateQueries({ queryKey: ['calculated-inventory'] });
            onClose();
        },
        onError: (e: any) => toast({ variant: 'destructive', title: 'Edit Failed', description: e.message })
    });

    if (!voucher) return null;

    return (
        <Dialog open={isOpen} onOpenChange={onClose}>
            <DialogContent className="bg-white rounded-none border-2 border-slate-900 shadow-2xl max-w-md">
                <DialogHeader>
                    <div className="flex items-center gap-2 text-slate-900 mb-2">
                        <Edit3 className="h-5 w-5" />
                        <DialogTitle className="text-xl font-black uppercase tracking-tighter">Voucher Revision</DialogTitle>
                    </div>
                </DialogHeader>

                <div className="space-y-6 py-4">
                    <div className="grid grid-cols-2 gap-4">
                        <div className="space-y-1">
                            <Label className="text-[10px] font-black uppercase text-slate-400">Voucher No</Label>
                            <div className="bg-slate-50 p-2 font-mono text-xs font-bold border border-slate-200">{voucher.voucher_no}</div>
                        </div>
                        <div className="space-y-1">
                            <Label className="text-[10px] font-black uppercase text-slate-400">Type</Label>
                            <div className="bg-slate-50 p-2 font-black text-[10px] uppercase border border-slate-200">{voucher.type}</div>
                        </div>
                    </div>

                    <div className="space-y-2">
                        <Label className="text-[10px] font-black uppercase text-slate-900">Revised Amount (PKR)</Label>
                        <div className="relative">
                            <span className="absolute left-3 top-1/2 -translate-y-1/2 font-bold text-slate-400 text-sm">Rs.</span>
                            <Input
                                type="number"
                                value={amount}
                                onChange={e => setAmount(e.target.value)}
                                className="h-12 pl-10 text-lg font-black rounded-none border-slate-300 focus:border-slate-900 focus:ring-0"
                            />
                        </div>
                    </div>

                    <div className="space-y-2">
                        <Label className="text-[10px] font-black uppercase text-slate-900">Revised Narration</Label>
                        <Input
                            value={narration}
                            onChange={e => setNarration(e.target.value)}
                            className="h-10 font-bold text-xs rounded-none border-slate-300 focus:border-slate-900 focus:ring-0"
                        />
                    </div>

                    <div className="bg-slate-900 p-4 text-white">
                        <p className="text-[9px] font-bold uppercase leading-relaxed tracking-wide">
                            Audit Note: Modifying this voucher will automatically trigger a full system reconciliation. Stock levels and ledger balances will be synchronized immediately.
                        </p>
                    </div>
                </div>

                <DialogFooter className="border-t pt-4">
                    <Button variant="outline" onClick={onClose} className="rounded-none font-black text-[10px] uppercase">Cancel</Button>
                    <Button
                        onClick={() => mutation.mutate()}
                        disabled={mutation.isPending}
                        className="rounded-none bg-slate-900 hover:bg-black text-white font-black text-[10px] uppercase px-8"
                    >
                        {mutation.isPending ? <Loader2 className="animate-spin h-3 w-3 mr-2" /> : null}
                        Commit Changes
                    </Button>
                </DialogFooter>
            </DialogContent>
        </Dialog>
    );
}
