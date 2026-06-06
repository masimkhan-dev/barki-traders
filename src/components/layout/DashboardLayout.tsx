import { useNavigate, Link } from 'react-router-dom';
import { ReactNode } from 'react';
import { Sidebar } from './Sidebar';
import { useAuth } from '@/contexts/AuthContext';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
  DropdownMenuSub,
  DropdownMenuSubTrigger,
  DropdownMenuSubContent,
  DropdownMenuPortal
} from '@/components/ui/dropdown-menu';
import { Button } from '@/components/ui/button';
import { ChevronDown, Building2, User, LogOut, Settings, BarChart3, ArrowRightLeft, Menu } from 'lucide-react';
import { useState } from 'react';
import {
  Sheet,
  SheetContent,
  SheetTrigger,
} from "@/components/ui/sheet";
import { BrandTitle } from '@/components/brand/BrandTitle';

interface DashboardLayoutProps {
  children: ReactNode;
}

export function DashboardLayout({ children }: DashboardLayoutProps) {
  const { user, role, signOut } = useAuth();
  const navigate = useNavigate();
  const [isMobileMenuOpen, setIsMobileMenuOpen] = useState(false);

  return (

    <div className="ledger-system min-h-screen bg-[#F8FAFC]">
      {/* MOBILE TRIGGER - Floating button for small screens */}
      <div className="lg:hidden fixed top-4 right-4 z-50">
        <Sheet open={isMobileMenuOpen} onOpenChange={setIsMobileMenuOpen}>
          <SheetTrigger asChild>
            <Button variant="outline" size="icon" className="h-11 w-11 rounded-none shadow-none bg-white border-slate-900 text-slate-900 border-2" aria-label="Open navigation menu">
              <Menu className="h-5 w-5" />
            </Button>
          </SheetTrigger>
          <SheetContent side="left" className="p-0 w-[280px] bg-slate-950 border-0">
            <Sidebar className="relative h-full" onItemClick={() => setIsMobileMenuOpen(false)} />
          </SheetContent>
        </Sheet>
      </div>

      <div className="flex">
        {/* Desktop Sidebar */}
        <Sidebar className="hidden lg:block fixed left-0 top-0 bottom-0 w-72 z-30" />

        {/* Main Content */}
        <main className="flex-1 lg:pl-72 min-w-0 flex flex-col min-h-screen">
          {/* TOP BAR */}
          <header className="sticky top-0 z-20 bg-white border-b border-slate-300 px-4 py-3 sm:px-6 lg:px-8 lg:py-4 flex items-center justify-between gap-4 shadow-none">
            <div className="flex items-center gap-2 lg:hidden">
              {/* Spacer for Mobile Menu Button */}
              <div className="w-8"></div>
            </div>

            <div className="flex items-center gap-2 min-w-0">
              <Building2 className="h-4 w-4 text-slate-400" />
              <div className="flex flex-col min-w-0">
                <BrandTitle variant="compact" className="text-slate-900 text-[10px] tracking-widest" />
                <span className="text-[10px] font-bold text-slate-400 uppercase tracking-normal truncate">Verified Ledger System</span>
              </div>
            </div>

            <div className="flex items-center gap-3 sm:gap-6 shrink-0">
              <div className="hidden sm:flex items-center gap-2 px-3 py-1 bg-slate-50 border border-slate-200">
                <div className="h-1.5 w-1.5 bg-emerald-600"></div>
                <span className="text-[10px] font-black uppercase text-slate-500 tracking-widest">Postings Verified</span>
              </div>
              <div className="flex items-center gap-3">
                <div className="text-right hidden sm:block">
                  <p className="text-[11px] font-black text-slate-900 uppercase leading-none">{user?.email?.split('@')[0]}</p>
                  <p className="text-[10px] font-bold text-slate-400 uppercase tracking-normal">{role || 'User'}</p>
                </div>
                <div className="h-8 w-8 rounded-none bg-slate-900 flex items-center justify-center text-white font-black text-xs border border-slate-800">
                  {user?.email?.charAt(0).toUpperCase() || 'A'}
                </div>
              </div>
            </div>
          </header>

          <div className="p-4 md:p-8 w-full flex-1">
            {children}
          </div>
        </main>
      </div>
    </div>

  );
}
