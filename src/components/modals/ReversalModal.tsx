
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
import { useAuth } from '@/contexts/AuthContext';

interface ReversalModalProps {
    voucherNo: string | null;
    isOpen: boolean;
    onClose: () => void;
}

export function ReversalModal({ voucherNo, isOpen, onClose }: ReversalModalProps) {
    const [reason, setReason] = useState('');
    const queryClient = useQueryClient();
    const { toast } = useToast();
    const { isAdmin } = useAuth();

    const mutation = useMutation({
        mutationFn: async () => {
            if (!voucherNo) return;
            if (!reason.trim()) throw new Error("Please provide a reason for reversal.");

            const { data, error } = await (supabase as any).rpc('reverse_transaction', {
                p_voucher_no: voucherNo,
                p_reason: reason
            });

            if (error) throw error;
            return data;
        },
        onSuccess: (data) => {
            toast({
                title: "Transaction Reversed",
                description: `Voucher ${voucherNo} has been neutralized. Reversal ID: ${data.reversal_voucher}`,
            });
            queryClient.invalidateQueries({ queryKey: ['roznamcha'] });
            queryClient.invalidateQueries({ queryKey: ['calculated-inventory'] });
            queryClient.invalidateQueries({ queryKey: ['all-accounts-fresh'] });
            queryClient.invalidateQueries({ queryKey: ['transaction-history'] });
            setReason('');
            onClose();
        },
        onError: (error: any) => {
            toast({
                variant: "destructive",
                title: "Reversal Failed",
                description: error.message,
            });
        }
    });

    return (
        <Dialog open={isOpen} onOpenChange={onClose}>
            <DialogContent className="sm:max-w-[425px]">
                <DialogHeader>
                    <DialogTitle className="flex items-center gap-2 text-rose-600 uppercase font-black">
                        <RotateCcw className="h-5 w-5" /> Confirm Reversal
                    </DialogTitle>
                    <DialogDescription className="font-medium text-slate-500 pt-2">
                        Yeh entry mukammal taur par <span className="font-bold text-slate-900 underline">ULAT</span> di jayegi.
                        Purana record delete nahi hoga, lekin uska asar khatam ho jayega.
                    </DialogDescription>
                </DialogHeader>

                <div className="py-6 space-y-4">
                    <div className="p-4 bg-amber-50 border-l-4 border-amber-400 rounded flex gap-3 text-amber-800 text-sm">
                        <AlertTriangle className="h-5 w-5 shrink-0" />
                        <p><strong>Dhyan dein:</strong> Stock aur accounts balance wapas purani halat mein aa jayein ge.</p>
                    </div>

                    <div className="space-y-2">
                        <Label htmlFor="reason" className="text-[10px] font-black uppercase text-slate-400">Reversal Reason (Wajah)</Label>
                        <Input
                            id="reason"
                            placeholder="e.g. Ghalat amount likh di thi..."
                            value={reason}
                            onChange={(e) => setReason(e.target.value)}
                            className="font-medium"
                        />
                    </div>
                </div>

                <DialogFooter className="gap-2">
                    <Button variant="ghost" onClick={onClose} disabled={mutation.isPending}>CANCEL</Button>
                    <Button
                        variant="destructive"
                        className="font-bold tracking-tight"
                        onClick={() => mutation.mutate()}
                        disabled={mutation.isPending || !reason.trim()}
                    >
                        {mutation.isPending ? <Loader2 className="animate-spin h-4 w-4 mr-2" /> : "REVERSE ENTRY"}
                    </Button>
                </DialogFooter>
            </DialogContent>
        </Dialog>
    );
}
