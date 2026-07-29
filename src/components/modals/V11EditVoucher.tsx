
import { useState, useEffect } from 'react';
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
import { Edit3 } from 'lucide-react';
import { PHASE1_EDIT_DELETE_MESSAGE } from '@/lib/phase1-readonly';

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
    const [amount, setAmount] = useState('');
    const [narration, setNarration] = useState('');

    useEffect(() => {
        if (voucher) {
            setAmount(String(Math.max(voucher.debit, voucher.credit)));
            setNarration(voucher.narration);
        }
    }, [voucher]);

    if (!voucher) return null;

    return (
        <Dialog open={isOpen} onOpenChange={onClose}>
            <DialogContent className="bg-white rounded-none border-2 border-slate-900 shadow-2xl max-w-md">
                <DialogHeader>
                    <div className="flex items-center gap-2 text-slate-900 mb-2">
                        <Edit3 className="h-5 w-5" />
                        <DialogTitle className="text-xl font-black uppercase tracking-tighter">Voucher Revision</DialogTitle>
                    </div>
                    <DialogDescription className="text-xs text-slate-500">
                        Revise voucher entry details.
                    </DialogDescription>
                </DialogHeader>

                <div className="p-4 bg-rose-50 border-l-4 border-rose-400 text-rose-900 text-sm mb-4">
                    <p className="font-bold">{PHASE1_EDIT_DELETE_MESSAGE}</p>
                </div>

                <div className="space-y-6 py-4 opacity-60 pointer-events-none">
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
                        <Input type="number" value={amount} readOnly className="h-12 text-lg font-black rounded-none" />
                    </div>

                    <div className="space-y-2">
                        <Label className="text-[10px] font-black uppercase text-slate-900">Revised Narration</Label>
                        <Input value={narration} readOnly className="h-10 font-bold text-xs rounded-none" />
                    </div>
                </div>

                <DialogFooter className="border-t pt-4">
                    <Button variant="outline" onClick={onClose} className="rounded-none font-black text-[10px] uppercase">
                        Close
                    </Button>
                    <Button disabled className="rounded-none bg-slate-400 text-white font-black text-[10px] uppercase px-8">
                        Edit disabled
                    </Button>
                </DialogFooter>
            </DialogContent>
        </Dialog>
    );
}
