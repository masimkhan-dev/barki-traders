import { useState } from 'react';
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
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
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from '@/components/ui/dialog';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog';
import { supabase } from '@/integrations/supabase/client';
import { useAuth } from '@/contexts/AuthContext';
import { useToast } from '@/hooks/use-toast';
import { formatDate } from '@/lib/format';
import { Plus, Loader2, UserCircle, Trash2, Shield, ShieldCheck } from 'lucide-react';
import { Constants } from '@/integrations/supabase/types';

type AppRole = 'admin' | 'accountant';

interface UserWithRole {
  id: string;
  user_id: string;
  role: AppRole;
  created_at: string;
  profile: {
    email: string;
    full_name: string | null;
    is_active: boolean;
  } | null;
}

interface Profile {
  id: string;
  email: string;
  full_name: string | null;
}

export default function Users() {
  const [isDialogOpen, setIsDialogOpen] = useState(false);
  const [deleteUserId, setDeleteUserId] = useState<string | null>(null);
  const [formData, setFormData] = useState({
    user_id: '',
    role: '' as AppRole | '',
  });

  const queryClient = useQueryClient();
  const { toast } = useToast();
  const { isAdmin, user: currentUser } = useAuth();

  // Fetch all users with roles
  // Fetch all users with roles (Decoupled to fix 400 Error)
  const { data: userRoles, isLoading } = useQuery({
    queryKey: ['user-roles'],
    queryFn: async () => {
      // 1. Fetch Roles (removed invalid order by created_at)
      const { data: roles, error: rolesError } = await supabase
        .from('user_roles')
        .select('*');

      if (rolesError) throw rolesError;
      if (!roles || roles.length === 0) return [];

      // 2. Fetch Profiles separately
      const userIds = roles.map((r: any) => r.user_id);
      const { data: profiles, error: profilesError } = await supabase
        .from('profiles')
        .select('id, email, full_name, is_active')
        .in('id', userIds);

      if (profilesError) throw profilesError;

      // 3. Merge Data
      return roles.map((role: any) => {
        const profile = profiles?.find((p: any) => p.id === role.user_id);
        return {
          ...role,
          profile: profile || null
        };
      }) as unknown as UserWithRole[];
    },
    enabled: !!isAdmin,
  });

  // Fetch all profiles for dropdown (users without roles)
  const { data: profiles } = useQuery({
    queryKey: ['profiles-without-roles'],
    queryFn: async () => {
      // Get all profiles
      const { data: allProfiles, error: profilesError } = await supabase
        .from('profiles')
        .select('id, email, full_name')
        .eq('is_active', true)
        .order('email');

      if (profilesError) throw profilesError;

      // Get existing user IDs with roles
      const { data: existingRoles, error: rolesError } = await supabase
        .from('user_roles')
        .select('user_id');

      if (rolesError) throw rolesError;

      const existingUserIds = new Set(existingRoles?.map(r => r.user_id) || []);

      // Filter out users who already have roles
      return (allProfiles as Profile[]).filter(p => !existingUserIds.has(p.id));
    },
    enabled: isAdmin,
  });

  const createMutation = useMutation({
    mutationFn: async (data: { user_id: string; role: AppRole }) => {
      const { error } = await supabase.from('user_roles').insert({
        user_id: data.user_id,
        role: data.role,
      });

      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['user-roles'] });
      queryClient.invalidateQueries({ queryKey: ['profiles-without-roles'] });
      setIsDialogOpen(false);
      setFormData({ user_id: '', role: '' });
      toast({
        title: 'Role Assigned',
        description: 'User role has been assigned successfully.',
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

  const deleteMutation = useMutation({
    mutationFn: async (roleId: string) => {
      const { error } = await supabase
        .from('user_roles')
        .delete()
        .eq('id', roleId);

      if (error) throw error;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['user-roles'] });
      queryClient.invalidateQueries({ queryKey: ['profiles-without-roles'] });
      setDeleteUserId(null);
      toast({
        title: 'Role Removed',
        description: 'User role has been removed successfully.',
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

    if (!formData.user_id || !formData.role) {
      toast({
        variant: 'destructive',
        title: 'Validation Error',
        description: 'Please select a user and role.',
      });
      return;
    }

    createMutation.mutate({ user_id: formData.user_id, role: formData.role as AppRole });
  };

  if (!isAdmin) {
    return (
      <DashboardLayout>
        <div className="text-center py-12">
          <Shield className="h-12 w-12 mx-auto text-destructive mb-4" />
          <p className="text-destructive font-semibold">Access Denied</p>
          <p className="text-muted-foreground mt-2">Only administrators can access this page.</p>
        </div>
      </DashboardLayout>
    );
  }

  const getRoleIcon = (role: AppRole) => {
    switch (role) {
      case 'admin':
        return <ShieldCheck className="h-4 w-4" />;
      case 'accountant':
        return <UserCircle className="h-4 w-4" />;
      default:
        return <UserCircle className="h-4 w-4" />;
    }
  };

  const getRoleBadgeClass = (role: AppRole) => {
    switch (role) {
      case 'admin':
        return 'bg-destructive/10 text-destructive border-destructive/20';
      case 'accountant':
        return 'bg-primary/10 text-primary border-primary/20';
      default:
        return 'bg-muted text-muted-foreground';
    }
  };

  return (
    <DashboardLayout>
      <div className="max-w-7xl mx-auto pb-20 px-4 py-8 print:p-0">

        {/* HEADER */}
        <div className="flex flex-col md:flex-row justify-between items-start md:items-end border-b-4 border-slate-900 pb-6 mb-8 gap-4">
          <div>
            <div className="flex items-center gap-2 mb-2">
              <Shield className="h-5 w-5 text-slate-600" />
              <span className="bg-slate-900 text-white text-[10px] px-2 py-0.5 font-black uppercase tracking-widest">Access Control</span>
            </div>
            <h1 className="text-3xl font-black text-slate-900 uppercase tracking-tighter">User Management</h1>
            <p className="text-slate-500 font-bold text-sm tracking-wide">User directory, role assignment & access permissions</p>
          </div>

          <Dialog open={isDialogOpen} onOpenChange={setIsDialogOpen}>
            <DialogTrigger asChild>
              <Button className="h-11 rounded-none border-2 border-slate-900 bg-slate-900 text-white font-black uppercase text-xs tracking-widest hover:bg-black transition-all px-6">
                <Plus className="h-4 w-4 mr-2" />
                Assign Role
              </Button>
            </DialogTrigger>
            <DialogContent className="max-w-md rounded-none border-2 border-slate-900">
              <DialogHeader>
                <DialogTitle className="flex items-center gap-2 font-black uppercase tracking-tight text-slate-900">
                  <Shield className="h-5 w-5" />
                  Assign User Role
                </DialogTitle>
              </DialogHeader>

              <form onSubmit={handleSubmit} className="space-y-4 mt-4">
                <div className="space-y-2">
                  <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">Select User *</Label>
                  <Select
                    value={formData.user_id}
                    onValueChange={(value) => setFormData(prev => ({ ...prev, user_id: value }))}
                  >
                    <SelectTrigger className="h-11 rounded-none border-slate-300 font-bold">
                      <SelectValue placeholder="Select a user" />
                    </SelectTrigger>
                    <SelectContent className="rounded-none border-slate-900">
                      {profiles && profiles.length > 0 ? (
                        profiles.map((profile) => (
                          <SelectItem key={profile.id} value={profile.id} className="font-bold text-xs">
                            {profile.email} {profile.full_name && `(${profile.full_name})`}
                          </SelectItem>
                        ))
                      ) : (
                        <div className="px-2 py-4 text-center text-[10px] font-black uppercase tracking-widest text-slate-400">
                          No users without roles found.
                          <br />
                          New users will appear here after signup.
                        </div>
                      )}
                    </SelectContent>
                  </Select>
                </div>

                <div className="space-y-2">
                  <Label className="text-[10px] uppercase font-black text-slate-500 tracking-widest">Select Role *</Label>
                  <Select
                    value={formData.role}
                    onValueChange={(value) => setFormData(prev => ({ ...prev, role: value as AppRole }))}
                  >
                    <SelectTrigger className="h-11 rounded-none border-slate-300 font-bold">
                      <SelectValue placeholder="Select a role" />
                    </SelectTrigger>
                    <SelectContent className="rounded-none border-slate-900">
                      {Constants.public.Enums.app_role.map((role) => (
                        <SelectItem key={role} value={role} className="font-bold text-xs uppercase">
                          <div className="flex items-center gap-2">
                            {getRoleIcon(role)}
                            {role}
                          </div>
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>

                <div className="p-4 bg-slate-50 border border-slate-200">
                  <p className="text-[10px] font-black uppercase tracking-widest text-slate-700 mb-2">Role Permissions</p>
                  <ul className="text-[10px] text-slate-500 space-y-1 font-bold uppercase tracking-tight">
                    <li>• <span className="text-rose-600">Admin:</span> Full access, user management, reports</li>
                    <li>• <span className="text-emerald-600">Accountant:</span> Transactions, customers, suppliers</li>
                  </ul>
                </div>

                <div className="flex justify-end gap-3 pt-4">
                  <Button type="button" variant="outline" onClick={() => setIsDialogOpen(false)} className="rounded-none font-black uppercase text-[10px] tracking-widest px-6">
                    Cancel
                  </Button>
                  <Button type="submit" disabled={createMutation.isPending || !profiles?.length} className="rounded-none bg-slate-900 hover:bg-black font-black uppercase text-[10px] tracking-widest px-6">
                    {createMutation.isPending && <Loader2 className="h-4 w-4 animate-spin mr-2" />}
                    Assign Role
                  </Button>
                </div>
              </form>
            </DialogContent>
          </Dialog>
        </div>

        {/* USER TABLE */}
        <div className="border border-slate-200 bg-white">
          <div className="bg-slate-900 px-6 py-3 flex items-center justify-between">
            <h3 className="font-black text-white text-[10px] uppercase tracking-[0.2em] flex items-center gap-2">
              <ShieldCheck className="h-3.5 w-3.5 text-slate-400" /> Active User Directory
            </h3>
            <div className="text-[9px] font-black bg-slate-800 px-3 py-1 text-slate-400 tracking-widest">
              {userRoles?.length || 0} USERS
            </div>
          </div>

          {isLoading ? (
            <div className="flex flex-col items-center justify-center py-20 gap-3">
              <Loader2 className="h-8 w-8 animate-spin text-slate-300" />
              <span className="text-[10px] font-black uppercase tracking-[0.2em] text-slate-400">Loading User Directory...</span>
            </div>
          ) : userRoles && userRoles.length > 0 ? (
            <div className="overflow-x-auto">
              <table className="w-full text-left border-collapse">
                <thead>
                  <tr className="bg-slate-100 border-b border-slate-200">
                    <th className="px-6 py-3 text-[10px] font-black uppercase tracking-widest text-slate-600">User</th>
                    <th className="px-6 py-3 text-[10px] font-black uppercase tracking-widest text-slate-600">Email</th>
                    <th className="px-6 py-3 text-[10px] font-black uppercase tracking-widest text-slate-600">Role</th>
                    <th className="px-6 py-3 text-[10px] font-black uppercase tracking-widest text-slate-600">Assigned On</th>
                    <th className="px-6 py-3 text-[10px] font-black uppercase tracking-widest text-slate-600">Status</th>
                    <th className="px-6 py-3 text-[10px] font-black uppercase tracking-widest text-slate-600 w-20">Actions</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {userRoles.map((userRole) => (
                    <tr key={userRole.id} className="hover:bg-slate-50/80 transition-colors">
                      <td className="px-6 py-4">
                        <div className="flex items-center gap-3">
                          <div className="flex h-8 w-8 items-center justify-center bg-slate-100 border border-slate-200">
                            <UserCircle className="h-4 w-4 text-slate-400" />
                          </div>
                          <span className="font-black text-xs text-slate-800 uppercase tracking-tight">
                            {userRole.profile?.full_name || 'No Name'}
                          </span>
                        </div>
                      </td>
                      <td className="px-6 py-4 text-xs font-bold text-slate-500">{userRole.profile?.email}</td>
                      <td className="px-6 py-4">
                        <span className={`inline-flex items-center gap-1.5 px-3 py-1 text-[10px] font-black uppercase tracking-wider border ${userRole.role === 'admin'
                            ? 'bg-rose-50 text-rose-700 border-rose-200'
                            : 'bg-emerald-50 text-emerald-700 border-emerald-200'
                          }`}>
                          {getRoleIcon(userRole.role)}
                          {userRole.role}
                        </span>
                      </td>
                      <td className="px-6 py-4 text-[10px] font-black text-slate-400 uppercase tracking-widest">{formatDate(userRole.created_at)}</td>
                      <td className="px-6 py-4">
                        <span className={`inline-flex items-center px-3 py-1 text-[10px] font-black uppercase tracking-wider border ${userRole.profile?.is_active
                            ? 'bg-emerald-50 text-emerald-700 border-emerald-200'
                            : 'bg-amber-50 text-amber-700 border-amber-200'
                          }`}>
                          {userRole.profile?.is_active ? 'Active' : 'Inactive'}
                        </span>
                      </td>
                      <td className="px-6 py-4">
                        {userRole.user_id !== currentUser?.id && (
                          <Button
                            variant="ghost"
                            size="sm"
                            className="h-8 w-8 p-0 text-rose-400 hover:text-rose-600 hover:bg-rose-50 rounded-none"
                            onClick={() => setDeleteUserId(userRole.id)}
                          >
                            <Trash2 className="h-3.5 w-3.5" />
                          </Button>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <div className="flex flex-col items-center justify-center py-20">
              <UserCircle className="h-12 w-12 text-slate-200 mb-4" />
              <p className="text-[10px] font-black uppercase tracking-widest text-slate-400 mb-6">No users with roles yet</p>
              <Button onClick={() => setIsDialogOpen(true)} className="rounded-none bg-slate-900 hover:bg-black font-black uppercase text-[10px] tracking-widest px-6">
                <Plus className="h-4 w-4 mr-2" />
                Assign First Role
              </Button>
            </div>
          )}
        </div>

      </div>

      {/* Delete Confirmation Dialog */}
      <AlertDialog open={!!deleteUserId} onOpenChange={() => setDeleteUserId(null)}>
        <AlertDialogContent className="rounded-none border-2 border-slate-900">
          <AlertDialogHeader>
            <AlertDialogTitle className="font-black uppercase tracking-tight text-slate-900">Remove User Role?</AlertDialogTitle>
            <AlertDialogDescription className="text-xs font-bold text-slate-500">
              This will remove the user's role and they will no longer be able to access the system.
              They can be assigned a new role later.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel className="rounded-none font-black uppercase text-[10px] tracking-widest">Cancel</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => deleteUserId && deleteMutation.mutate(deleteUserId)}
              className="rounded-none bg-rose-600 text-white hover:bg-rose-700 font-black uppercase text-[10px] tracking-widest"
            >
              {deleteMutation.isPending && <Loader2 className="h-4 w-4 animate-spin mr-2" />}
              Remove Role
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </DashboardLayout>
  );
}
