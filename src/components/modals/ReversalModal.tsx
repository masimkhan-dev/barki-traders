
import { useState } from 'react';
import {
    Dialog,
    DialogContent,
    DialogDescription,
    DialogHeader,
    DialogTitle,
    DialogFooter,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { supabase } from '@/integrations/supabase/client';
import { useToast } from '@/hooks/use-toast';
import { Loader2, AlertTriangle, RotateCcw } from 'lucide-react';

interface ReversalModalProps {
    voucherNo: string | null;
    isOpen: boolean;
    onClose: () => void;
}

type ReverseTransactionResult = {
    success?: boolean;
    reversal_voucher?: string;
    error?: string;
};

export function ReversalModal({ voucherNo, isOpen, onClose }: ReversalModalProps) {
    const [reason, setReason] = useState('');
    const queryClient = useQueryClient();
    const { toast } = useToast();
    const mutation = useMutation({
        mutationFn: async () => {
            if (!voucherNo) throw new Error('No voucher selected.');
            if (!reason.trim()) throw new Error('Please provide a reversal reason.');

            const { data, error } = await supabase.rpc('reverse_transaction', {
                p_voucher_no: voucherNo,
                p_reason: reason.trim(),
            });

            if (error) throw error;

            const result = data as ReverseTransactionResult | null;
            if (result?.success === false) {
                throw new Error(result.error || 'Reversal failed.');
            }

            return result;
        },
        onSuccess: (data) => {
            toast({
                title: 'Transaction Reversed',
                description: `Voucher ${voucherNo} has been neutralized. Reversal ID: ${data?.reversal_voucher ?? 'REV-' + voucherNo}`,
            });
            queryClient.invalidateQueries({ queryKey: ['roznamcha'] });
            queryClient.invalidateQueries({ queryKey: ['roznamcha-v2'] });
            queryClient.invalidateQueries({ queryKey: ['roznamcha-v3'] });
            queryClient.invalidateQueries({ queryKey: ['calculated-inventory'] });
            queryClient.invalidateQueries({ queryKey: ['all-accounts-fresh'] });
            queryClient.invalidateQueries({ queryKey: ['transaction-history'] });
            queryClient.invalidateQueries({ queryKey: ['recent-factory-vouchers'] });
            queryClient.invalidateQueries({ queryKey: ['sales'] });
            queryClient.invalidateQueries({ queryKey: ['purchases'] });
            queryClient.invalidateQueries({ queryKey: ['ledger_entries'] });
            setReason('');
            onClose();
        },
        onError: (error: Error) => {
            toast({
                variant: 'destructive',
                title: 'Reversal Failed',
                description: error.message,
            });
        },
    });

    return (
        <Dialog open={isOpen} onOpenChange={onClose}>
            <DialogContent className="sm:max-w-[480px] rounded-none border-2 border-slate-900 p-0 overflow-hidden">
                <DialogHeader>
                    <DialogTitle className="flex items-center gap-2 text-rose-600 uppercase font-black px-6 pt-6">
                        <RotateCcw className="h-5 w-5" /> Confirm Reversal
                    </DialogTitle>
                    <DialogDescription className="font-medium text-slate-500 pt-2 px-6 leading-relaxed">
                        Yeh entry mukammal taur par <span className="font-bold text-slate-900 underline">ULAT</span> di jayegi.
                        Purana record delete nahi hoga, lekin uska asar khatam ho jayega.
                    </DialogDescription>
                </DialogHeader>

                <div className="px-6 py-6 space-y-4">
                    <div className="p-4 bg-amber-50 border-l-4 border-amber-400 rounded-none flex gap-3 text-amber-800 text-sm">
                        <AlertTriangle className="h-5 w-5 shrink-0" />
                        <p><strong>Dhyan dein:</strong> Stock aur accounts balance wapas purani halat mein aa jayein ge.</p>
                    </div>

                    {voucherNo && (
                        <div className="p-3 bg-slate-50 border border-slate-200 rounded-none text-sm font-mono font-bold text-slate-700">
                            {voucherNo}
                        </div>
                    )}

                    <div className="space-y-2">
                        <Label htmlFor="reason" className="text-[10px] font-black uppercase text-slate-400">Reversal Reason (Wajah)</Label>
                        <Input
                            id="reason"
                            placeholder="e.g. Ghalat amount likh di thi..."
                            value={reason}
                            onChange={(e) => setReason(e.target.value)}
                            className="h-11 rounded-none border-slate-300 font-medium"
                            disabled={mutation.isPending}
                        />
                    </div>
                </div>

                <DialogFooter className="gap-2 border-t border-slate-200 bg-slate-50 px-6 py-4">
                    <Button variant="ghost" className="h-10" onClick={onClose} disabled={mutation.isPending}>CANCEL</Button>
                    <Button
                        variant="destructive"
                        className="h-10 font-bold tracking-tight"
                        onClick={() => mutation.mutate()}
                        disabled={mutation.isPending || !reason.trim()}
                    >
                        {mutation.isPending ? (
                            <Loader2 className="h-4 w-4 animate-spin mr-2" />
                        ) : (
                            <RotateCcw className="h-4 w-4 mr-2" />
                        )}
                        REVERSE VOUCHER
                    </Button>
                </DialogFooter>
            </DialogContent>
        </Dialog>
    );
}
