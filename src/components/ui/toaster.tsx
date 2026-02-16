import { useToast } from "@/hooks/use-toast";
import {
  Toast,
  ToastClose,
  ToastDescription,
  ToastProvider,
  ToastTitle,
  ToastViewport,
} from "@/components/ui/toast";
import { Check, X, AlertTriangle, Info } from "lucide-react";
import { cn } from "@/lib/utils";

export function Toaster() {
  const { toasts } = useToast();

  return (
    <ToastProvider duration={3000}>
      {toasts.map(function ({ id, title, description, action, ...props }) {
        // Determine style based on variant
        const isError = props.variant === "destructive";
        // Heuristic: If we had a 'warning' variant, we'd check it. 
        // For now, default is Success, 'destructive' is Error.

        let borderColor = "border-emerald-500";
        let Icon = Check;
        let iconColor = "text-emerald-600";

        if (isError) {
          borderColor = "border-rose-500";
          Icon = X;
          iconColor = "text-rose-600";
        }

        // Overriding generic styles to match "Government Audit" aesthetic
        return (
          <Toast
            key={id}
            {...props}
            className={cn(
              "grid grid-cols-[auto_1fr] items-start gap-4 p-4",
              "w-full max-w-[320px] bg-white shadow-lg",
              "border-l-4 border-t-0 border-b-0 border-r-0 rounded-none",
              borderColor,
              // Force background to white and text to slate-800 to override default shadcn styles
              "!bg-white !text-slate-800",
              // Animation
              "data-[state=open]:animate-in data-[state=closed]:animate-out data-[swipe=end]:animate-out",
              "data-[state=closed]:fade-out-80 data-[state=closed]:slide-out-to-right-full",
              "data-[state=open]:slide-in-from-right-full data-[state=open]:duration-500"
            )}
          >
            <div className={cn("mt-0.5", iconColor)}>
              <Icon className="h-4 w-4" strokeWidth={3} />
            </div>

            <div className="grid gap-1">
              {title && (
                <ToastTitle className="text-xs font-black uppercase tracking-widest text-slate-800 leading-none">
                  {title}
                </ToastTitle>
              )}
              {description && (
                <ToastDescription className="text-[10px] font-bold text-slate-500 uppercase tracking-wide leading-tight mt-1">
                  {description}
                </ToastDescription>
              )}
            </div>
            {/* Action usually rendered as a button, ensuring it fits style */}
            {action}
            {/* Close button removed as per requirements */}
          </Toast>
        );
      })}
      <ToastViewport className="fixed bottom-0 right-0 flex flex-col p-6 gap-2 w-full max-w-[420px] z-[100] outline-none" />
    </ToastProvider>
  );
}
