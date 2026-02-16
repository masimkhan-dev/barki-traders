
import { ReactNode } from 'react';
import { cn } from '@/lib/utils';
import { TrendingUp, TrendingDown } from 'lucide-react';

interface StatCardProps {
  title: string;
  value: string | number | ReactNode;
  subtitle?: string;
  icon?: ReactNode;
  trend?: {
    value: number;
    isPositive: boolean;
  };
  variant?: 'default' | 'primary' | 'success' | 'warning' | 'accent' | 'destructive';
}

const variantStyles = {
  default: 'bg-card',
  primary: 'bg-primary/5 border-primary/20',
  success: 'bg-success/5 border-success/20',
  warning: 'bg-warning/5 border-warning/20',
  accent: 'bg-accent/5 border-accent/20',
  destructive: 'bg-destructive/5 border-destructive/20',
};

const iconStyles = {
  default: 'bg-muted text-muted-foreground',
  primary: 'bg-primary/10 text-primary',
  success: 'bg-success/10 text-success',
  warning: 'bg-warning/10 text-warning',
  accent: 'bg-accent/10 text-accent',
  destructive: 'bg-destructive/10 text-destructive',
};

export function StatCard({
  title,
  value,
  subtitle,
  icon,
  trend,
  variant = 'default'
}: StatCardProps) {
  return (
    <div className={cn('stat-card animate-slide-up', variantStyles[variant])}>
      <div className="flex items-start justify-between">
        <div className="flex-1">
          <p className="text-sm font-medium text-muted-foreground mb-1">{title}</p>
          <div className="text-2xl font-bold text-foreground">
            {value}
          </div>

          {(subtitle || trend) && (
            <div className="flex items-center gap-2 mt-2">
              {trend && (
                <span className={cn(
                  'flex items-center text-xs font-medium',
                  trend.isPositive ? 'text-success' : 'text-destructive'
                )}>
                  {trend.isPositive ? (
                    <TrendingUp className="h-3 w-3 mr-1" />
                  ) : (
                    <TrendingDown className="h-3 w-3 mr-1" />
                  )}
                  {Math.abs(trend.value)}%
                </span>
              )}
              {subtitle && (
                <span className="text-xs text-muted-foreground">{subtitle}</span>
              )}
            </div>
          )}
        </div>

        {icon && (
          <div className={cn(
            'flex h-12 w-12 items-center justify-center rounded-xl',
            iconStyles[variant]
          )}>
            {icon}
          </div>
        )}
      </div>
    </div>
  );
}
