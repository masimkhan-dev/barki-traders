import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { supabase } from '@/integrations/supabase/client';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { useToast } from '@/hooks/use-toast';
import { Building2, Lock, Loader2, CheckCircle2, KeyRound } from 'lucide-react';

export default function ResetPassword() {
    const navigate = useNavigate();
    const { toast } = useToast();
    const [loading, setLoading] = useState(false);
    const [success, setSuccess] = useState(false);
    const [password, setPassword] = useState('');
    const [confirmPassword, setConfirmPassword] = useState('');
    const [error, setError] = useState('');

    const handleSubmit = async (e: React.FormEvent) => {
        e.preventDefault();
        setError('');

        if (password.length < 6) {
            setError('Password must be at least 6 characters');
            return;
        }
        if (password !== confirmPassword) {
            setError('Passwords do not match');
            return;
        }

        setLoading(true);
        try {
            const { error } = await supabase.auth.updateUser({ password });
            if (error) {
                toast({ variant: 'destructive', title: 'Error', description: error.message });
            } else {
                setSuccess(true);
                toast({ title: 'Password Updated', description: 'Your password has been changed successfully.' });
                setTimeout(() => navigate('/'), 3000);
            }
        } finally {
            setLoading(false);
        }
    };

    return (
        <div className="min-h-screen flex items-center justify-center bg-slate-50 p-8">
            <div className="w-full max-w-[400px] animate-in fade-in slide-in-from-bottom-4 duration-500">

                <div className="text-center mb-10">
                    <div className="inline-flex h-14 w-14 items-center justify-center rounded-none bg-slate-900 mb-4 border border-white/10 p-2 shadow-xl">
                        <img src="/logo.svg" alt="Naveed Musazai" className="h-full w-full object-contain filter brightness-110" />
                    </div>
                    <h1 className="text-2xl font-black uppercase tracking-tight text-slate-900 leading-none">Naveed<br /><span className="text-slate-500">Musazai</span></h1>
                    <p className="text-[9px] font-black uppercase tracking-[0.4em] text-slate-500 mt-4 pl-1">Audit Ledger System</p>
                </div>

                <div className="mb-8">
                    <h2 className="text-2xl font-bold tracking-tight text-slate-900">Set New Password</h2>
                    <p className="text-sm text-slate-500 mt-2">Enter your new password below</p>
                </div>

                {success ? (
                    <div className="p-6 bg-emerald-50 border border-emerald-200 text-center space-y-3">
                        <CheckCircle2 className="h-10 w-10 text-emerald-600 mx-auto" />
                        <p className="text-sm font-bold text-emerald-800">Password updated successfully!</p>
                        <p className="text-xs text-emerald-600">Redirecting to login...</p>
                    </div>
                ) : (
                    <form onSubmit={handleSubmit} className="space-y-5">
                        <div className="space-y-1.5">
                            <Label className="text-xs font-bold uppercase tracking-wide text-slate-500">New Password</Label>
                            <div className="relative group">
                                <Lock className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400 group-focus-within:text-slate-900 transition-colors" />
                                <Input
                                    type="password"
                                    placeholder="••••••••"
                                    className="pl-10 h-10 bg-white border-slate-200 focus:border-slate-900 focus:ring-slate-900/10 transition-all font-medium"
                                    value={password}
                                    onChange={e => setPassword(e.target.value)}
                                />
                            </div>
                        </div>

                        <div className="space-y-1.5">
                            <Label className="text-xs font-bold uppercase tracking-wide text-slate-500">Confirm Password</Label>
                            <div className="relative group">
                                <Lock className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400 group-focus-within:text-slate-900 transition-colors" />
                                <Input
                                    type="password"
                                    placeholder="••••••••"
                                    className="pl-10 h-10 bg-white border-slate-200 focus:border-slate-900 focus:ring-slate-900/10 transition-all font-medium"
                                    value={confirmPassword}
                                    onChange={e => setConfirmPassword(e.target.value)}
                                />
                            </div>
                        </div>

                        {error && <p className="text-xs font-medium text-rose-600">{error}</p>}

                        <Button
                            type="submit"
                            className="w-full h-11 bg-slate-900 hover:bg-slate-800 text-white font-bold tracking-wide uppercase text-xs transition-all duration-200"
                            disabled={loading}
                        >
                            {loading ? (
                                <div className="flex items-center gap-2">
                                    <Loader2 className="h-4 w-4 animate-spin" />
                                    <span>Updating...</span>
                                </div>
                            ) : (
                                <div className="flex items-center gap-2">
                                    <KeyRound className="h-4 w-4" />
                                    <span>Update Password</span>
                                </div>
                            )}
                        </Button>
                    </form>
                )}
            </div>
        </div>
    );
}
