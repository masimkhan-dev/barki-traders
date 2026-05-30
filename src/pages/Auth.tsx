import { useState, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { useAuth } from '@/contexts/AuthContext';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Building2, Mail, Lock, User, ArrowRight, Loader2, ShieldCheck, TrendingUp, BarChart3, KeyRound } from 'lucide-react';
import { z } from 'zod';
import { supabase } from '@/integrations/supabase/client';
import { useToast } from '@/hooks/use-toast';
import { cn } from '@/lib/utils';

const loginSchema = z.object({
  email: z.string().email('Please enter a valid email'),
  password: z.string().min(6, 'Password must be at least 6 characters'),
});

const signupSchema = loginSchema.extend({
  fullName: z.string().min(2, 'Name must be at least 2 characters'),
  confirmPassword: z.string(),
}).refine(data => data.password === data.confirmPassword, {
  message: "Passwords don't match",
  path: ['confirmPassword'],
});

type AuthMode = 'login' | 'signup' | 'forgot';

export default function Auth() {
  const navigate = useNavigate();
  const { signIn, signUp, user, role, loading: authLoading } = useAuth();
  const [mode, setMode] = useState<AuthMode>('login');
  const [loading, setLoading] = useState(false);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const { toast } = useToast();
  const [resetSent, setResetSent] = useState(false);

  const [formData, setFormData] = useState({
    email: '',
    password: '',
    confirmPassword: '',
    fullName: '',
  });

  // ✅ Redirect when auth + role both ready (handles async role fetch after login)
  useEffect(() => {
    if (!authLoading && user && role) {
      navigate(role === 'accountant' ? '/roznamcha' : '/dashboard', { replace: true });
    }
  }, [user, role, authLoading, navigate]);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setErrors({});
    setLoading(true);

    try {
      if (mode === 'forgot') {
        if (!formData.email || !z.string().email().safeParse(formData.email).success) {
          setErrors({ email: 'Please enter a valid email address' });
          setLoading(false);
          return;
        }
        const { error } = await supabase.auth.resetPasswordForEmail(formData.email, {
          redirectTo: `${window.location.origin}/reset-password`,
        });
        if (error) {
          toast({ variant: 'destructive', title: 'Error', description: error.message });
        } else {
          setResetSent(true);
          toast({ title: 'Reset Link Sent', description: 'Check your email inbox for the password reset link.' });
        }
      } else if (mode === 'login') {
        const result = loginSchema.safeParse(formData);
        if (!result.success) {
          const fieldErrors: Record<string, string> = {};
          result.error.errors.forEach(err => {
            fieldErrors[err.path[0]] = err.message;
          });
          setErrors(fieldErrors);
          setLoading(false);
          return;
        }

        const { error } = await signIn(formData.email, formData.password);
        if (!error) {
          // Component will re-render and redirect based on role
        }
      } else {
        const result = signupSchema.safeParse(formData);
        if (!result.success) {
          const fieldErrors: Record<string, string> = {};
          result.error.errors.forEach(err => {
            fieldErrors[err.path[0]] = err.message;
          });
          setErrors(fieldErrors);
          setLoading(false);
          return;
        }

        const { error } = await signUp(formData.email, formData.password, formData.fullName);
        if (!error) {
          setMode('login');
        }
      }
    } finally {
      setLoading(false);
    }
  };

  const handleInputChange = (field: string) => (e: React.ChangeEvent<HTMLInputElement>) => {
    setFormData(prev => ({ ...prev, [field]: e.target.value }));
    if (errors[field]) {
      setErrors(prev => ({ ...prev, [field]: '' }));
    }
  };

  return (
    <div className="min-h-screen grid lg:grid-cols-2">

      {/* LEFT PANEL: Brand & Value (Desktop Only) */}
      <div className="hidden lg:flex relative bg-slate-950 flex-col justify-between p-12 text-white overflow-hidden">
        {/* Abstract Background Pattern */}
        <div className="absolute inset-0 opacity-10">
          <svg className="h-full w-full" viewBox="0 0 100 100" preserveAspectRatio="none">
            <path d="M0 100 C 20 0 50 0 100 100 Z" fill="currentColor" />
          </svg>
        </div>

        {/* Top Brand */}
        <div className="relative z-10 flex items-center gap-3">
          <div className="flex h-12 w-12 items-center justify-center rounded-lg bg-white/10 border border-white/10 backdrop-blur-sm">
            <Building2 className="h-6 w-6 text-white" />
          </div>
          <div>
            <h1 className="text-xl font-black tracking-tight uppercase leading-none">NAVEED<br /><span className="text-slate-500">MUSAZAI</span></h1>
          </div>
        </div>

        {/* Middle Content */}
        <div className="relative z-10 max-w-lg space-y-8">
          <h2 className="text-5xl font-bold tracking-tight leading-tight">
            Financial <span className="text-emerald-500">Audit</span> &<br />
            Control System
          </h2>
          <p className="text-lg text-slate-400 font-medium leading-relaxed">
            A complete enterprise resource planning solution designed for precise inventory tracking, double-entry accounting, and real-time financial reporting.
          </p>

          <div className="grid grid-cols-1 gap-6 pt-4">
            <div className="flex items-center gap-4">
              <div className="h-10 w-10 rounded-full bg-emerald-500/10 flex items-center justify-center border border-emerald-500/20">
                <ShieldCheck className="h-5 w-5 text-emerald-500" />
              </div>
              <div>
                <h3 className="font-bold text-white text-sm uppercase tracking-wide">Secure Ledger</h3>
                <p className="text-slate-500 text-xs mt-1">Immutable transaction recording</p>
              </div>
            </div>
            <div className="flex items-center gap-4">
              <div className="h-10 w-10 rounded-full bg-blue-500/10 flex items-center justify-center border border-blue-500/20">
                <BarChart3 className="h-5 w-5 text-blue-500" />
              </div>
              <div>
                <h3 className="font-bold text-white text-sm uppercase tracking-wide">Real-time Analytics</h3>
                <p className="text-slate-500 text-xs mt-1">Instant P&L and Balance Sheet</p>
              </div>
            </div>
          </div>
        </div>

        {/* Footer */}
        <div className="relative z-10 text-xs text-slate-500 font-medium tracking-widest uppercase">
          &copy; {new Date().getFullYear()} Naveed Musazai Enterprise.
        </div>
      </div>

      {/* RIGHT PANEL: Auth Form */}
      <div className="flex flex-col items-center justify-center p-8 bg-slate-50">
        <div className="w-full max-w-[400px] animate-in fade-in slide-in-from-bottom-4 duration-500">

          {/* Mobile Header (Visible only on small screens) */}
          <div className="lg:hidden text-center mb-10">
            <div className="inline-flex h-12 w-12 items-center justify-center rounded-lg bg-slate-900 mb-4">
              <Building2 className="h-6 w-6 text-white" />
            </div>
            <h1 className="text-2xl font-black uppercase tracking-tight text-slate-900">Naveed Musazai</h1>
            <p className="text-xs font-bold uppercase tracking-widest text-slate-500 mt-2">Audit Ledger System</p>
          </div>

          <div className="mb-8">
            <h2 className="text-2xl font-bold tracking-tight text-slate-900">
              {mode === 'forgot' ? 'Reset your password' : mode === 'login' ? 'Sign in to platform' : 'Create new account'}
            </h2>
            <p className="text-sm text-slate-500 mt-2">
              {mode === 'forgot' ? 'Enter your email and we\'ll send you a reset link' : mode === 'login' ? 'Enter your credentials to access your dashboard' : 'Register your details for administrative review'}
            </p>
          </div>

          <form onSubmit={handleSubmit} className="space-y-5">
            {mode === 'forgot' ? (
              <>
                {resetSent ? (
                  <div className="p-6 bg-emerald-50 border border-emerald-200 text-center space-y-3">
                    <Mail className="h-10 w-10 text-emerald-600 mx-auto" />
                    <p className="text-sm font-bold text-emerald-800">Reset link sent to your email!</p>
                    <p className="text-xs text-emerald-600">Check your inbox and click the link to set a new password.</p>
                  </div>
                ) : (
                  <div className="space-y-1.5">
                    <Label htmlFor="email" className="text-xs font-bold uppercase tracking-wide text-slate-500">Email Address</Label>
                    <div className="relative group">
                      <Mail className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400 group-focus-within:text-slate-900 transition-colors" />
                      <Input
                        id="email"
                        type="email"
                        placeholder="name@company.com"
                        className="pl-10 h-10 bg-white border-slate-200 focus:border-slate-900 focus:ring-slate-900/10 transition-all font-medium"
                        value={formData.email}
                        onChange={handleInputChange('email')}
                      />
                    </div>
                    {errors.email && <p className="text-xs font-medium text-rose-600">{errors.email}</p>}
                  </div>
                )}

                {!resetSent && (
                  <Button
                    type="submit"
                    className="w-full h-11 bg-slate-900 hover:bg-slate-800 text-white font-bold tracking-wide uppercase text-xs transition-all duration-200 disabled:opacity-70 disabled:cursor-not-allowed"
                    disabled={loading}
                  >
                    {loading ? (
                      <div className="flex items-center gap-2">
                        <Loader2 className="h-4 w-4 animate-spin" />
                        <span>Sending...</span>
                      </div>
                    ) : (
                      <div className="flex items-center gap-2">
                        <KeyRound className="h-4 w-4" />
                        <span>Send Reset Link</span>
                      </div>
                    )}
                  </Button>
                )}

                <button
                  type="button"
                  onClick={() => { setMode('login'); setResetSent(false); setErrors({}); }}
                  className="w-full text-center text-sm font-bold text-slate-900 hover:underline mt-2"
                >
                  ← Back to Login
                </button>
              </>
            ) : (
              <>
                {mode === 'signup' && (
                  <div className="space-y-1.5">
                    <Label htmlFor="fullName" className="text-xs font-bold uppercase tracking-wide text-slate-500">Full Name</Label>
                    <div className="relative group">
                      <User className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400 group-focus-within:text-slate-900 transition-colors" />
                      <Input
                        id="fullName"
                        type="text"
                        placeholder="e.g. Ali Khan"
                        className="pl-10 h-10 bg-white border-slate-200 focus:border-slate-900 focus:ring-slate-900/10 transition-all font-medium"
                        value={formData.fullName}
                        onChange={handleInputChange('fullName')}
                      />
                    </div>
                    {errors.fullName && <p className="text-xs font-medium text-rose-600">{errors.fullName}</p>}
                  </div>
                )}

                <div className="space-y-1.5">
                  <Label htmlFor="email" className="text-xs font-bold uppercase tracking-wide text-slate-500">Email Address</Label>
                  <div className="relative group">
                    <Mail className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400 group-focus-within:text-slate-900 transition-colors" />
                    <Input
                      id="email"
                      type="email"
                      placeholder="name@company.com"
                      className="pl-10 h-10 bg-white border-slate-200 focus:border-slate-900 focus:ring-slate-900/10 transition-all font-medium"
                      value={formData.email}
                      onChange={handleInputChange('email')}
                    />
                  </div>
                  {errors.email && <p className="text-xs font-medium text-rose-600">{errors.email}</p>}
                </div>

                <div className="space-y-1.5">
                  <div className="flex items-center justify-between">
                    <Label htmlFor="password" className="text-xs font-bold uppercase tracking-wide text-slate-500">Password</Label>
                    {mode === 'login' && (
                      <button type="button" onClick={() => { setMode('forgot'); setErrors({}); setResetSent(false); }} className="text-xs font-medium text-slate-900 hover:underline">Forgot password?</button>
                    )}
                  </div>
                  <div className="relative group">
                    <Lock className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400 group-focus-within:text-slate-900 transition-colors" />
                    <Input
                      id="password"
                      type="password"
                      placeholder="••••••••"
                      className="pl-10 h-10 bg-white border-slate-200 focus:border-slate-900 focus:ring-slate-900/10 transition-all font-medium"
                      value={formData.password}
                      onChange={handleInputChange('password')}
                    />
                  </div>
                  {errors.password && <p className="text-xs font-medium text-rose-600">{errors.password}</p>}
                </div>

                {mode === 'signup' && (
                  <div className="space-y-1.5">
                    <Label htmlFor="confirmPassword" className="text-xs font-bold uppercase tracking-wide text-slate-500">Confirm Password</Label>
                    <div className="relative group">
                      <Lock className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400 group-focus-within:text-slate-900 transition-colors" />
                      <Input
                        id="confirmPassword"
                        type="password"
                        placeholder="••••••••"
                        className="pl-10 h-10 bg-white border-slate-200 focus:border-slate-900 focus:ring-slate-900/10 transition-all font-medium"
                        value={formData.confirmPassword}
                        onChange={handleInputChange('confirmPassword')}
                      />
                    </div>
                    {errors.confirmPassword && <p className="text-xs font-medium text-rose-600">{errors.confirmPassword}</p>}
                  </div>
                )}

                <Button
                  type="submit"
                  className="w-full h-11 bg-slate-900 hover:bg-slate-800 text-white font-bold tracking-wide uppercase text-xs transition-all duration-200 disabled:opacity-70 disabled:cursor-not-allowed"
                  disabled={loading}
                >
                  {loading ? (
                    <div className="flex items-center gap-2">
                      <Loader2 className="h-4 w-4 animate-spin" />
                      <span>Processing...</span>
                    </div>
                  ) : (
                    <div className="flex items-center gap-2">
                      <span>{mode === 'login' ? 'Secure Login' : 'Register Account'}</span>
                      <ArrowRight className="h-4 w-4" />
                    </div>
                  )}
                </Button>
              </>
            )}
          </form>

          <div className="mt-8 text-center space-y-4">
            <div className="relative">
              <div className="absolute inset-0 flex items-center">
                <span className="w-full border-t border-slate-200" />
              </div>
              <div className="relative flex justify-center text-xs uppercase">
                <span className="bg-slate-50 px-2 text-slate-400 font-medium">Or continue with</span>
              </div>
            </div>

            {mode !== 'forgot' && (
              <p className="text-sm font-medium text-slate-600">
                {mode === 'login' ? "New to the system?" : 'Already registered?'}
                <button
                  type="button"
                  onClick={() => {
                    setMode(mode === 'login' ? 'signup' : 'login');
                    setErrors({});
                  }}
                  className="ml-1 text-slate-900 font-bold hover:underline"
                >
                  {mode === 'login' ? 'Request Access' : 'Sign in'}
                </button>
              </p>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
