import { useNavigate, Link, useLocation } from 'react-router-dom';
import { ReactNode, useState } from 'react';
import { Sidebar } from './Sidebar';
import { useAuth } from '@/contexts/AuthContext';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Button } from '@/components/ui/button';
import { useToast } from '@/hooks/use-toast';
import { supabase } from '@/integrations/supabase/client';
import {
  ChevronDown,
  Building2,
  User,
  LogOut,
  Settings,
  BarChart3,
  ArrowRightLeft,
  Menu,
  LayoutDashboard,
  CalendarDays,
  ShoppingCart,
  Truck,
  Package,
  BookOpen,
  FileText,
  Receipt,
  Wallet,
  FileMinus,
  UserCircle,
  KeyRound,
  Loader2,
  Lock,
  DatabaseBackup
} from 'lucide-react';
import {
  Sheet,
  SheetContent,
  SheetTrigger,
} from "@/components/ui/sheet";
import { clientConfig } from '@/lib/client-config';
import { cn } from '@/lib/utils';

interface DashboardLayoutProps {
  children: ReactNode;
}

export function DashboardLayout({ children }: DashboardLayoutProps) {
  const { user, role, signOut } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const { toast } = useToast();
  const [isMobileMenuOpen, setIsMobileMenuOpen] = useState(false);
  const [isPasswordModalOpen, setIsPasswordModalOpen] = useState(false);
  const [newPassword, setNewPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [passwordLoading, setPasswordLoading] = useState(false);

  // Role checks for dropdown items
  const isAllOperations = role === 'admin' || role === 'accountant';
  const isAdminOnly = role === 'admin';

  const handlePasswordChange = async (e: React.FormEvent) => {
    e.preventDefault();
    if (newPassword.length < 6) {
      toast({ variant: 'destructive', title: 'Error', description: 'Password must be at least 6 characters' });
      return;
    }
    if (newPassword !== confirmPassword) {
      toast({ variant: 'destructive', title: 'Error', description: 'Passwords do not match' });
      return;
    }

    setPasswordLoading(true);
    try {
      const { error } = await supabase.auth.updateUser({ password: newPassword });
      if (error) {
        toast({ variant: 'destructive', title: 'Error', description: error.message });
      } else {
        toast({ title: 'Success', description: 'Password changed successfully' });
        setIsPasswordModalOpen(false);
        setNewPassword('');
        setConfirmPassword('');
      }
    } finally {
      setPasswordLoading(false);
    }
  };

  const isActivePath = (path: string) => {
    const [itemPath, itemSearch] = path.split('?');
    return (
      location.pathname === itemPath &&
      (!itemSearch || location.search === `?${itemSearch}`)
    );
  };

  return (
    <div className="ledger-system min-h-screen bg-[var(--color-page-bg)] flex flex-col">
      {/* TOP NAVBAR (Desktop & Mobile Wrapper) */}
      <header className="sticky top-0 z-40 h-16 bg-[#16162A] text-white border-b border-[#2E2E42] px-4 sm:px-6 lg:px-8 flex items-center justify-between gap-4 shadow-md">
        
        {/* BRAND & MOBILE TRIGGER */}
        <div className="flex items-center gap-2">
          {/* Mobile Menu Button */}
          <div className="lg:hidden">
            <Sheet open={isMobileMenuOpen} onOpenChange={setIsMobileMenuOpen}>
              <SheetTrigger asChild>
                <Button variant="ghost" size="icon" className="h-10 w-10 text-white hover:bg-white/10" aria-label="Open menu">
                  <Menu className="h-5 w-5" />
                </Button>
              </SheetTrigger>
              <SheetContent side="left" className="p-0 w-[280px] bg-slate-950 border-0">
                <Sidebar className="relative h-full" onItemClick={() => setIsMobileMenuOpen(false)} />
              </SheetContent>
            </Sheet>
          </div>

          <Link to="/" className="flex items-center gap-3 focus-visible:outline-white">
            <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-[#2E2E42] border border-[#3E3E5C] overflow-hidden p-1">
              <img src={clientConfig.LOGO_PATH} alt={clientConfig.BUSINESS_NAME} className="h-full w-full object-contain filter brightness-110" />
            </div>
            <div className="flex flex-col min-w-0">
              <span className="text-white text-[12px] font-black tracking-wide uppercase leading-none">NEXLY</span>
              <span className="text-[9px] font-bold text-slate-400 uppercase tracking-[0.1em] mt-0.5">{clientConfig.BUSINESS_NAME}</span>
            </div>
          </Link>
        </div>

        {/* DESKTOP HORIZONTAL MENU */}
        <nav className="hidden lg:flex items-center gap-1 xl:gap-2 h-full text-slate-300 font-semibold text-xs" aria-label="Desktop primary navigation">
          
          {/* Dashboard Link */}
          <Link
            to="/dashboard"
            className={cn(
              "flex items-center gap-1.5 px-3 py-2 rounded-md transition-colors hover:text-white hover:bg-white/5",
              isActivePath('/dashboard') && "text-white bg-white/10 font-bold"
            )}
          >
            <LayoutDashboard className="h-3.5 w-3.5" />
            <span>Dashboard</span>
          </Link>

          {/* Operations Dropdown */}
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button
                className={cn(
                  "flex items-center gap-1 px-3 py-2 rounded-md transition-colors hover:text-white hover:bg-white/5 focus:outline-none",
                  (isActivePath('/roznamcha') || isActivePath('/manage-transactions') || isActivePath('/inventory') || isActivePath('/ledger')) && "text-white bg-white/10 font-bold"
                )}
              >
                <ArrowRightLeft className="h-3.5 w-3.5" />
                <span>Operations</span>
                <ChevronDown className="h-3 w-3 opacity-60" />
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent className="w-56 bg-slate-900 border border-slate-800 text-slate-200 rounded-md p-1.5 shadow-xl">
              {isAllOperations && (
                <>
                  <DropdownMenuItem asChild>
                    <Link to="/roznamcha" className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                      <CalendarDays className="h-3.5 w-3.5 text-slate-400" />
                      <span>Daily Diary</span>
                    </Link>
                  </DropdownMenuItem>
                  <DropdownMenuItem asChild>
                    <Link to="/manage-transactions?type=SALE" className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                      <ShoppingCart className="h-3.5 w-3.5 text-slate-400" />
                      <span>Fuel Sale</span>
                    </Link>
                  </DropdownMenuItem>
                  <DropdownMenuItem asChild>
                    <Link to="/manage-transactions?type=PURCHASE" className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                      <Truck className="h-3.5 w-3.5 text-slate-400" />
                      <span>Fuel Purchase</span>
                    </Link>
                  </DropdownMenuItem>
                  <DropdownMenuItem asChild>
                    <Link to="/manage-transactions?type=ACTION_CENTER" className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                      <ArrowRightLeft className="h-3.5 w-3.5 text-slate-400" />
                      <span>Transactions</span>
                    </Link>
                  </DropdownMenuItem>
                </>
              )}
              <DropdownMenuItem asChild>
                <Link to="/inventory" className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                  <Package className="h-3.5 w-3.5 text-slate-400" />
                  <span>Stock</span>
                </Link>
              </DropdownMenuItem>
              <DropdownMenuItem asChild>
                <Link to="/ledger" className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                  <BookOpen className="h-3.5 w-3.5 text-slate-400" />
                  <span>Ledger</span>
                </Link>
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>

          {/* Reports Dropdown */}
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button
                className={cn(
                  "flex items-center gap-1 px-3 py-2 rounded-md transition-colors hover:text-white hover:bg-white/5 focus:outline-none",
                  (location.pathname.startsWith('/reports/')) && "text-white bg-white/10 font-bold"
                )}
              >
                <BarChart3 className="h-3.5 w-3.5" />
                <span>Reports</span>
                <ChevronDown className="h-3 w-3 opacity-60" />
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent className="w-56 bg-slate-900 border border-slate-800 text-slate-200 rounded-md p-1.5 shadow-xl">
              <DropdownMenuItem asChild>
                <Link to="/reports/account-statement" className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                  <FileText className="h-3.5 w-3.5 text-slate-400" />
                  <span>Party Statement</span>
                </Link>
              </DropdownMenuItem>
              <DropdownMenuItem asChild>
                <Link to="/reports/business" className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                  <BarChart3 className="h-3.5 w-3.5 text-slate-400" />
                  <span>Market Position</span>
                </Link>
              </DropdownMenuItem>
              <DropdownMenuItem asChild>
                <Link to="/reports/profit-loss" className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                  <Receipt className="h-3.5 w-3.5 text-slate-400" />
                  <span>Income Statement</span>
                </Link>
              </DropdownMenuItem>
              <DropdownMenuItem asChild>
                <Link to="/reports/trial-balance" className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                  <Wallet className="h-3.5 w-3.5 text-slate-400" />
                  <span>Trial Balance</span>
                </Link>
              </DropdownMenuItem>
              <DropdownMenuItem asChild>
                <Link to="/reports/balance-sheet" className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                  <FileMinus className="h-3.5 w-3.5 text-slate-400" />
                  <span>Balance Sheet</span>
                </Link>
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>

          {/* Admin Dropdown */}
          {isAllOperations && (
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <button
                  className={cn(
                    "flex items-center gap-1 px-3 py-2 rounded-md transition-colors hover:text-white hover:bg-white/5 focus:outline-none",
                    (isActivePath('/settings/coa') || isActivePath('/settings/backup') || isActivePath('/users')) && "text-white bg-white/10 font-bold"
                  )}
                >
                  <Settings className="h-3.5 w-3.5" />
                  <span>Admin</span>
                  <ChevronDown className="h-3 w-3 opacity-60" />
                </button>
              </DropdownMenuTrigger>
              <DropdownMenuContent className="w-56 bg-slate-900 border border-slate-800 text-slate-200 rounded-md p-1.5 shadow-xl">
                <DropdownMenuItem asChild>
                  <Link to="/settings/coa" className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                    <Building2 className="h-3.5 w-3.5 text-slate-400" />
                    <span>Manage Accounts</span>
                  </Link>
                </DropdownMenuItem>
                <DropdownMenuItem asChild>
                  <Link to="/settings/backup" className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                    <DatabaseBackup className="h-3.5 w-3.5 text-slate-400" />
                    <span>Backup Center</span>
                  </Link>
                </DropdownMenuItem>
                {isAdminOnly && (
                  <DropdownMenuItem asChild>
                    <Link to="/users" className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                      <UserCircle className="h-3.5 w-3.5 text-slate-400" />
                      <span>Access Control</span>
                    </Link>
                  </DropdownMenuItem>
                )}
              </DropdownMenuContent>
            </DropdownMenu>
          )}
        </nav>

        {/* RIGHT SIDE SECTION: STATUS & USER MENU */}
        <div className="flex items-center gap-3 sm:gap-6 shrink-0 text-slate-200">
          {/* Postings Verified Status Indicator */}
          <div className="hidden sm:flex items-center gap-2 px-3 py-1 bg-[#10b981]/15 border border-[#10b981]/20 rounded-full">
            <div className="h-1.5 w-1.5 rounded-full bg-[#10b981]"></div>
            <span className="text-[10px] font-black uppercase text-[#10b981] tracking-wider">Postings Verified</span>
          </div>

          <div className="flex items-center gap-3">
            <div className="text-right hidden sm:block">
              <p className="text-[11px] font-bold uppercase leading-none text-white">{user?.email?.split('@')[0]}</p>
              <p className="text-[9px] font-bold text-slate-400 uppercase tracking-widest mt-1">{role || 'User'}</p>
            </div>
            
            {/* User Settings Dropdown */}
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <button className="h-9 w-9 rounded-full bg-[var(--color-primary)] hover:bg-[var(--color-primary-dark)] transition-colors flex items-center justify-center text-white font-bold text-sm border border-[#2E2E42] focus:outline-none focus:ring-1 focus:ring-white/20">
                  {user?.email?.charAt(0).toUpperCase() || 'A'}
                </button>
              </DropdownMenuTrigger>
              <DropdownMenuContent className="w-56 bg-slate-900 border border-slate-800 text-slate-200 rounded-md p-1.5 shadow-xl mt-1.5" align="end">
                <div className="px-2.5 py-2 border-b border-slate-800 mb-1 lg:hidden">
                  <p className="text-[11px] font-bold uppercase leading-none text-white">{user?.email?.split('@')[0]}</p>
                  <p className="text-[9px] font-bold text-slate-400 uppercase tracking-widest mt-1">{role || 'User'}</p>
                </div>
                <DropdownMenuItem onClick={() => setIsPasswordModalOpen(true)} className="flex items-center gap-2 px-2.5 py-2 hover:bg-white/10 rounded-sm cursor-pointer text-xs">
                  <KeyRound className="h-3.5 w-3.5 text-slate-400" />
                  <span>Change Password</span>
                </DropdownMenuItem>
                <DropdownMenuSeparator className="bg-slate-800" />
                <DropdownMenuItem onClick={signOut} className="flex items-center gap-2 px-2.5 py-2 text-rose-400 hover:text-rose-300 hover:bg-rose-500/10 rounded-sm cursor-pointer text-xs">
                  <LogOut className="h-3.5 w-3.5" />
                  <span className="uppercase tracking-wider font-semibold">Sign Out</span>
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </div>
      </header>

      {/* PASSWORD CHANGE MODAL */}
      <Dialog open={isPasswordModalOpen} onOpenChange={setIsPasswordModalOpen}>
        <DialogContent className="sm:max-w-[425px] bg-slate-900 border border-slate-800 text-slate-200 rounded-lg p-6">
          <DialogHeader className="mb-4">
            <DialogTitle className="text-white text-base font-bold flex items-center gap-2 uppercase tracking-wide">
              <KeyRound className="h-4 w-4 text-[var(--color-primary)]" />
              Change System Password
            </DialogTitle>
          </DialogHeader>
          <form onSubmit={handlePasswordChange} className="space-y-4">
            <div className="space-y-1">
              <label className="text-[10px] font-bold uppercase tracking-wider text-slate-400">New Password</label>
              <input
                type="password"
                placeholder="Enter new password (min 6 chars)"
                value={newPassword}
                onChange={e => setNewPassword(e.target.value)}
                className="w-full h-10 rounded-md px-3 text-xs bg-slate-950 border border-slate-800 text-white placeholder:text-slate-600 focus:outline-none focus:border-[var(--color-primary)]"
                required
              />
            </div>
            <div className="space-y-1">
              <label className="text-[10px] font-bold uppercase tracking-wider text-slate-400">Confirm Password</label>
              <input
                type="password"
                placeholder="Confirm new password"
                value={confirmPassword}
                onChange={e => setConfirmPassword(e.target.value)}
                className="w-full h-10 rounded-md px-3 text-xs bg-slate-950 border border-slate-800 text-white placeholder:text-slate-600 focus:outline-none focus:border-[var(--color-primary)]"
                required
              />
            </div>
            <div className="flex justify-end gap-3 pt-2">
              <Button type="button" variant="ghost" className="h-10 text-xs border border-transparent text-slate-400 hover:bg-white/5" onClick={() => setIsPasswordModalOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" disabled={passwordLoading} className="h-10 text-xs bg-[var(--color-primary)] hover:bg-[var(--color-primary-dark)] text-white px-5 uppercase tracking-widest font-semibold flex items-center gap-2">
                {passwordLoading && <Loader2 className="h-3.5 w-3.5 animate-spin" />}
                Update Password
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>

      {/* MAIN CONTENT AREA */}
      <main className="flex-1 w-full flex flex-col min-h-[calc(100vh-4rem)]">
        <div className="p-4 md:p-8 w-full flex-1">
          {children}
        </div>
      </main>
    </div>
  );
}
