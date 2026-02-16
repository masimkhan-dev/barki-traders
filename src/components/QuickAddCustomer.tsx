import { useState, useEffect } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from '@/components/ui/dialog';
import { supabase } from '@/integrations/supabase/client';
import { useToast } from '@/hooks/use-toast';
import { Loader2, PlusCircle } from 'lucide-react';

interface QuickAddCustomerProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCustomerCreated: (customerId: string) => void;
  type?: 'customer' | 'supplier';
}

export function QuickAddCustomer({ open, onOpenChange, onCustomerCreated, type = 'customer' }: QuickAddCustomerProps) {
  const [name, setName] = useState('');
  const [phone, setPhone] = useState('');
  const [openingBalance, setOpeningBalance] = useState('0');
  const queryClient = useQueryClient();
  const { toast } = useToast();

  // Reset form when opened
  useEffect(() => {
    if (open) {
      setName('');
      setPhone('');
      setOpeningBalance('0');
    }
  }, [open]);

  const createMutation = useMutation({
    mutationFn: async () => {
      const ob = parseFloat(openingBalance) || 0;

      // 1. Create the party with opening_balance = 0
      //    (opening balance goes into ledger, not parties table)
      const { data, error } = await supabase
        .from('parties')
        .insert({
          name: name.trim(),
          phone: phone.trim() || null,
          type: type,
          opening_balance: 0,
          current_balance: 0,
        })
        .select('id')
        .single();

      if (error) throw error;

      // 2. If opening balance is non-zero, post proper ledger entry
      if (ob !== 0) {
        const { error: rpcError } = await (supabase as any).rpc('initialize_party_opening_balance', {
          p_party_id: data.id,
          p_opening_balance: ob,
          p_opening_date: new Date().toISOString().split('T')[0],
        });
        // If RPC doesn't exist yet, fall back to storing on parties table
        if (rpcError) {
          console.warn('initialize_party_opening_balance RPC not available, using fallback:', rpcError.message);
          await supabase
            .from('parties')
            .update({ opening_balance: ob, current_balance: ob })
            .eq('id', data.id);
        }
      }

      return data;
    },
    onSuccess: (data) => {
      queryClient.invalidateQueries({ queryKey: ['all-accounts-fresh'] });
      toast({
        title: 'Account Created',
        description: `${name} has been added successfully with opening balance ${openingBalance}.`,
      });
      onCustomerCreated(data.id);
      onOpenChange(false);
    },
    onError: (error) => {
      toast({
        variant: 'destructive',
        title: 'Error',
        description: error.message,
      });
    },
  });

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      toast({
        variant: 'destructive',
        title: 'Validation Error',
        description: 'Account name is required.',
      });
      return;
    }
    createMutation.mutate();
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-sm border-2 border-slate-300 rounded-none shadow-xl p-0 gap-0 bg-white">
        <DialogHeader className="bg-slate-900 px-6 py-4">
          <DialogTitle className="flex items-center gap-2 text-white text-sm font-black uppercase tracking-wider">
            <PlusCircle className="h-4 w-4" />
            New {type === 'customer' ? 'Customer' : 'Supplier'} Account
          </DialogTitle>
          <DialogDescription className="text-slate-400 text-[10px] uppercase tracking-wider font-bold">
            Enter the details below to register a new ledger account.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit} className="px-6 py-5 space-y-5">
          <div className="space-y-1.5">
            <Label htmlFor="quick-name" className="text-[10px] uppercase font-black text-slate-500 tracking-wider">
              Account Name <span className="text-rose-500">*</span>
            </Label>
            <Input
              id="quick-name"
              placeholder="e.g. Bhai Jaan Transport"
              value={name}
              onChange={(e) => setName(e.target.value)}
              autoFocus
              className="h-11 bg-white font-bold text-slate-900 border-slate-300 rounded-none shadow-sm focus:ring-slate-900 focus:border-slate-900 placeholder:text-slate-300 placeholder:font-normal"
            />
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="quick-phone" className="text-[10px] uppercase font-black text-slate-500 tracking-wider">
              Phone Number
            </Label>
            <Input
              id="quick-phone"
              placeholder="03XX-XXXXXXX"
              value={phone}
              onChange={(e) => setPhone(e.target.value)}
              className="h-11 bg-white font-bold text-slate-900 border-slate-300 rounded-none shadow-sm focus:ring-slate-900 focus:border-slate-900 placeholder:text-slate-300 placeholder:font-normal"
            />
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="quick-opening" className="text-[10px] uppercase font-black text-slate-500 tracking-wider">
              Opening Balance (PKR) <span className="text-rose-500">*</span>
            </Label>
            <Input
              id="quick-opening"
              type="number"
              step="0.01"
              placeholder="0.00"
              value={openingBalance}
              onChange={(e) => setOpeningBalance(e.target.value)}
              className="h-11 bg-white font-black text-lg text-slate-900 border-slate-300 rounded-none shadow-sm focus:ring-slate-900 focus:border-slate-900 placeholder:text-slate-300 placeholder:font-normal"
            />
            <p className="text-[9px] text-slate-400 italic font-medium leading-relaxed">
              {type === 'customer'
                ? "Agar customer ne purana paisa Dena hai toh yahan likhen."
                : "Agar supplier ko purana paisa Dena baqi hai toh minus (-) mein likhen."
              }
            </p>
          </div>

          <div className="flex justify-end gap-2 pt-3 border-t border-slate-200">
            <Button
              type="button"
              variant="outline"
              onClick={() => onOpenChange(false)}
              className="rounded-none border-slate-300 text-[10px] font-black uppercase tracking-widest px-5 h-10 hover:bg-slate-50"
            >
              Cancel
            </Button>
            <Button
              type="submit"
              disabled={createMutation.isPending}
              className="rounded-none bg-slate-900 hover:bg-black text-[10px] font-black uppercase tracking-widest px-5 h-10"
            >
              {createMutation.isPending && <Loader2 className="h-3.5 w-3.5 animate-spin mr-1.5" />}
              Create Account
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  );
}
