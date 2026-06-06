import { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import { DashboardLayout } from '@/components/layout/DashboardLayout';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from '@/components/ui/dialog';
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from '@/components/ui/tabs';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { useToast } from '@/hooks/use-toast';
import { formatNumber } from '@/lib/format';
import { Fuel, AlertTriangle, TrendingUp, TrendingDown, Loader2, Plus, Edit, Package, ArrowRight } from 'lucide-react';
import { cn } from '@/lib/utils';
import { useInventory } from '@/hooks/useInventory';
import { useNavigate } from 'react-router-dom';

interface FuelType {
  id: string;
  name: string;
  unit: string;
  is_active: boolean;
  created_at: string;
}

export default function Inventory() {
  const navigate = useNavigate();
  const [isDialogOpen, setIsDialogOpen] = useState(false);
  const [editingFuelType, setEditingFuelType] = useState<FuelType | null>(null);
  const [formData, setFormData] = useState({
    name: '',
    unit: 'Liters',
  });

  const queryClient = useQueryClient();
  const { toast } = useToast();
  const { isAccountant, isAdmin } = useAuth();

  // Use calculated inventory instead of buggy inventory table
  const { data: inventory, isLoading } = useInventory();

  const { data: fuelTypes, isLoading: loadingFuelTypes } = useQuery({
    queryKey: ['fuel-types-all'],
    queryFn: async () => {
      const { data, error } = await supabase
        .from('fuel_types')
        .select('*')
        .order('name');

      if (error) throw error;
      return data as FuelType[];
    },
  });

  const createMutation = useMutation({
    mutationFn: async (data: { name: string; unit: string }) => {
      const { error } = await supabase.from('fuel_types').insert({
        name: data.name.trim(),
        unit: data.unit.trim(),
      });

      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['fuel-types-all'] });
      queryClient.invalidateQueries({ queryKey: ['fuel-types'] });
      queryClient.invalidateQueries({ queryKey: ['calculated-inventory'] });
      setIsDialogOpen(false);
      setFormData({ name: '', unit: 'Liters' });
      toast({
        title: 'Fuel Type Added',
        description: 'New fuel type has been added successfully.',
      });
    },
    onError: (error) => {
      toast({
        variant: 'destructive',
        title: 'Error',
        description: error.message,
      });
    },
  });

  const updateMutation = useMutation({
    mutationFn: async (data: { id: string; name: string; unit: string; is_active: boolean }) => {
      const { error } = await supabase
        .from('fuel_types')
        .update({
          name: data.name.trim(),
          unit: data.unit.trim(),
          is_active: data.is_active,
        })
        .eq('id', data.id);

      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['fuel-types-all'] });
      queryClient.invalidateQueries({ queryKey: ['fuel-types'] });
      queryClient.invalidateQueries({ queryKey: ['calculated-inventory'] });
      setEditingFuelType(null);
      setFormData({ name: '', unit: 'Liters' });
      toast({
        title: 'Fuel Type Updated',
        description: 'Fuel type has been updated successfully.',
      });
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

    if (!formData.name.trim()) {
      toast({
        variant: 'destructive',
        title: 'Validation Error',
        description: 'Please enter a fuel type name.',
      });
      return;
    }

    if (editingFuelType) {
      updateMutation.mutate({
        id: editingFuelType.id,
        name: formData.name,
        unit: formData.unit,
        is_active: editingFuelType.is_active,
      });
    } else {
      createMutation.mutate(formData);
    }
  };

  const openEditDialog = (fuelType: FuelType) => {
    setEditingFuelType(fuelType);
    setFormData({ name: fuelType.name, unit: fuelType.unit });
  };

  const toggleActive = (fuelType: FuelType) => {
    updateMutation.mutate({
      id: fuelType.id,
      name: fuelType.name,
      unit: fuelType.unit,
      is_active: !fuelType.is_active,
    });
  };

  const LOW_STOCK_THRESHOLD = 1000;
  const MAX_CAPACITY = 50000;

  return (


    <DashboardLayout>
      <div className="max-w-7xl mx-auto pb-20 print:p-0">
        <Tabs defaultValue="stock" className="space-y-0">
          {/* STICKY HEADER & TABS BAR */}

          <div className="sticky-filter-bar print:hidden px-4">
            <div className="max-w-7xl mx-auto flex flex-col md:flex-row items-start md:items-center justify-between gap-6">
              <div className="report-header mb-0">
                <h1 className="report-title">Inventory & Stock Ledger</h1>
                <p className="report-subtitle">Real-time Petroleum Stock Auditing & Product Configuration</p>
              </div>

              <TabsList className="bg-slate-100 p-1 border border-slate-200 rounded-sm h-auto w-full sm:w-auto grid grid-cols-2">
                <TabsTrigger value="stock" className="rounded-none data-[state=active]:bg-white data-[state=active]:shadow-sm text-[10px] font-black uppercase tracking-widest px-6 h-9">
                  <Package className="h-3.5 w-3.5 mr-2" />
                  Physical Stock
                </TabsTrigger>
                <TabsTrigger value="fuel-types" className="rounded-none data-[state=active]:bg-white data-[state=active]:shadow-sm text-[10px] font-black uppercase tracking-widest px-6 h-9">
                  <Fuel className="h-3.5 w-3.5 mr-2" />
                  Item Registry
                </TabsTrigger>
              </TabsList>
            </div>
          </div>

          <div className="px-4 space-y-6 mt-6">


            <TabsContent value="stock">
              {isLoading ? (
                <div className="flex flex-col items-center justify-center min-h-[40vh] gap-4">
                  <Loader2 className="h-10 w-10 animate-spin text-slate-300" />
                  <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-400">Auditing Physical Stock...</span>
                </div>
              ) : (
                <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
                  {inventory && inventory.length > 0 ? inventory.map((item) => {
                    const isLow = item.current_stock < LOW_STOCK_THRESHOLD && item.current_stock > 0;
                    const isNegative = item.current_stock < 0;
                    const percentage = Math.min(Math.max((item.current_stock / MAX_CAPACITY) * 100, 0), 100);

                    return (
                      <div
                        key={item.fuel_type_id}
                        className={cn(
                          'border p-5 sm:p-6 bg-white flex flex-col min-w-0',
                          isNegative ? 'border-rose-500 border-2' : isLow ? 'border-amber-500 border-2' : 'border-slate-300'
                        )}
                      >
                        <div className="flex items-start justify-between mb-6">
                          <div className="flex flex-col">
                            <h3 className="text-[10px] font-black uppercase text-slate-400 tracking-widest">{item.fuel_type_name}</h3>
                              <span className="text-[10px] font-bold text-slate-400 uppercase">Unit: {item.fuel_type_unit}</span>
                          </div>

                          {isNegative ? (
                            <div className="flex items-center gap-1 text-rose-600 animate-pulse">
                              <AlertTriangle className="h-4 w-4" />
                              <span className="text-[10px] font-black uppercase">Oversold</span>
                            </div>
                          ) : isLow ? (
                            <div className="flex items-center gap-1 text-amber-600">
                              <AlertTriangle className="h-4 w-4" />
                              <span className="text-[10px] font-black uppercase">Critical Stock</span>
                            </div>
                          ) : null}
                        </div>

                        <div className="mb-6">
                          <p className={cn(
                            'text-4xl font-black num-audit',
                            isNegative ? 'text-rose-600' : 'text-slate-900'
                          )}>
                            {formatNumber(item.current_stock)}
                          </p>
                          <p className="text-[10px] font-bold text-slate-400 uppercase tracking-normal mt-1">Liters in Storage</p>
                        </div>

                        {/* Stock breakdown */}
                        <div className="mb-6 text-[10px] font-bold uppercase tracking-tighter space-y-2 p-3 bg-slate-50 border border-slate-100">
                          <div className="flex justify-between">
                            <span className="text-assets">Total Inward (Purchases):</span>
                            <span className="num-audit text-assets">{formatNumber(item.total_purchased)} L</span>
                          </div>
                          <div className="flex justify-between">
                            <span className="text-liabilities">Total Outward (Sales):</span>
                            <span className="num-audit text-liabilities">{formatNumber(item.total_sold)} L</span>
                          </div>
                        </div>

                        <div>
                          <div className="flex items-center justify-between text-[10px] font-black uppercase text-slate-400 mb-2">
                            <span>Tank Capacity Level</span>
                            <span>{isNegative ? 'ERR: NEGATIVE' : `${percentage.toFixed(1)}%`}</span>
                          </div>
                          <div className="h-1 bg-slate-100 overflow-hidden">
                            <div
                              className={cn(
                                'h-full transition-all duration-700 ease-out',
                                isNegative ? 'bg-rose-500' : isLow ? 'bg-amber-500' : 'bg-emerald-500'
                              )}
                              style={{ width: `${isNegative ? 100 : percentage}%` }}
                            />
                          </div>
                        </div>

                        <div className="mt-auto pt-6 flex gap-2">
                          <Button 
                            variant="outline" 
                            className="flex-1 rounded-none h-8 text-[9px] font-black uppercase tracking-widest border-slate-200 hover:border-rose-400 hover:text-rose-600 hover:bg-rose-50 group"
                            onClick={() => navigate(`/manage-transactions?type=SHRINKAGE&fuel_type_id=${item.fuel_type_id}`)}
                          >
                            Record Shrinkage
                            <ArrowRight className="h-3 w-3 ml-2 opacity-0 group-hover:opacity-100 transition-all" />
                          </Button>
                        </div>
                      </div>
                    );
                  }) : (
                    <div className="md:col-span-2 lg:col-span-3 center-align py-20 border border-dashed border-slate-300 bg-white text-slate-400">
                      <Package className="h-10 w-10 mx-auto mb-4 text-slate-300" />
                      <p className="text-[11px] font-black uppercase tracking-widest">No stock records available</p>
                    </div>
                  )}
                </div>
              )}
            </TabsContent>

            <TabsContent value="fuel-types">
              <div className="border border-slate-300 bg-white p-6">
                <div className="flex items-center justify-between mb-6 pb-4 border-b border-slate-200">
                  <h2 className="text-sm font-black uppercase tracking-widest text-slate-800">Master Data: Fuel Products</h2>

                  {(isAdmin || isAccountant) && (
                    <Dialog open={isDialogOpen} onOpenChange={(open) => {
                      setIsDialogOpen(open);
                      if (!open) {
                        setEditingFuelType(null);
                        setFormData({ name: '', unit: 'Liters' });
                      }
                    }}>
                      <DialogTrigger asChild>
                        <Button className="rounded-none font-bold uppercase text-[10px] tracking-widest h-9 bg-slate-900">
                          <Plus className="h-3 w-3 mr-2" />
                          Configure New Product
                        </Button>
                      </DialogTrigger>
                    <DialogContent className="max-w-md rounded-none border-2 border-slate-900 p-0 overflow-hidden">
                        <DialogHeader>
                          <DialogTitle className="text-sm font-black uppercase tracking-widest px-6 pt-6">
                            {editingFuelType ? 'Update Product Details' : 'Initialize New Fuel Product'}
                          </DialogTitle>
                        </DialogHeader>

                        <form onSubmit={handleSubmit} className="space-y-5 p-6 pt-2">
                          <div className="space-y-2">
                            <Label className="text-[10px] font-black uppercase">Product Designation</Label>
                            <Input
                              className="rounded-none border-slate-300 font-bold text-xs h-11"
                              placeholder="e.g. MS PETROL"
                              value={formData.name}
                              onChange={(e) => setFormData(prev => ({ ...prev, name: e.target.value }))}
                            />
                          </div>

                          <div className="space-y-2">
                            <Label className="text-[10px] font-black uppercase">Measure Unit</Label>
                            <Input
                              className="rounded-none border-slate-300 font-bold text-xs h-11"
                              placeholder="Liters"
                              value={formData.unit}
                              onChange={(e) => setFormData(prev => ({ ...prev, unit: e.target.value }))}
                            />
                          </div>

                          <div className="flex justify-end gap-3 pt-6">
                            <Button type="button" variant="outline" className="rounded-none text-[10px] font-black uppercase px-6" onClick={() => setIsDialogOpen(false)}>
                              Abort
                            </Button>
                            <Button type="submit" className="rounded-none text-[10px] font-black uppercase px-6 bg-slate-900" disabled={createMutation.isPending || updateMutation.isPending}>
                              {editingFuelType ? 'Save Configuration' : 'Commit to Database'}
                            </Button>
                          </div>
                        </form>
                      </DialogContent>
                    </Dialog>
                  )}
                </div>

                {loadingFuelTypes ? (
                  <div className="flex flex-col items-center justify-center py-20 gap-3">
                    <Loader2 className="h-6 w-6 animate-spin text-slate-300" />
                    <span className="text-[9px] font-black uppercase tracking-[0.2em] text-slate-400">Retrieving Product Definitions...</span>
                  </div>
                ) : fuelTypes && fuelTypes.length > 0 ? (
                  <div className="audit-table-shell">
                    <table className="ledger-table">
                      <thead>
                        <tr>
                          <th>Designation</th>
                          <th>Standard Unit</th>
                          <th className="center-align">Audit Status</th>
                          <th>Created On</th>
                          {(isAdmin || isAccountant) && <th className="w-24 center-align">Actions</th>}
                        </tr>
                      </thead>
                      <tbody>
                        {fuelTypes.map((fuelType) => (
                          <tr key={fuelType.id}>
                            <td className="font-bold text-slate-900 uppercase">{fuelType.name}</td>
                            <td className="uppercase">{fuelType.unit}</td>
                            <td className="center-align">
                              <button
                                onClick={() => (isAdmin || isAccountant) && toggleActive(fuelType)}
                                disabled={!(isAdmin || isAccountant)}
                                className={cn(
                                  'px-2 py-0.5 text-[9px] font-black uppercase border',
                                  fuelType.is_active
                                    ? 'bg-emerald-50 text-emerald-800 border-emerald-200'
                                    : 'bg-slate-50 text-slate-400 border-slate-200'
                                )}
                              >
                                {fuelType.is_active ? 'Active' : 'Deactivated'}
                              </button>
                            </td>
                            <td className="num-audit text-xs text-slate-500">
                              {new Date(fuelType.created_at).toLocaleDateString('en-PK')}
                            </td>
                            {(isAdmin || isAccountant) && (
                              <td className="center-align">
                                <Button
                                  variant="ghost"
                                  size="sm"
                                  className="h-7 w-7 p-0"
                                  aria-label={`Edit ${fuelType.name}`}
                                  onClick={() => {
                                    openEditDialog(fuelType);
                                    setIsDialogOpen(true);
                                  }}
                                >
                                  <Edit className="h-3 w-3" />
                                </Button>
                              </td>
                            )}
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                ) : (
                  <div className="center-align py-20 opacity-30 italic">
                    No products configured in database.
                  </div>
                )}
              </div>
            </TabsContent>
          </div>
        </Tabs>

      </div>
    </DashboardLayout >

  );
}
