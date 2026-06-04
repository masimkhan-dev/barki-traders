import { clientConfig, getLogoLines } from '@/lib/client-config';
import { cn } from '@/lib/utils';

type BrandTitleProps = {
  /** Stacked logo lines (sidebar/auth); single-line report title; compact uppercase header */
  variant?: 'stacked' | 'report' | 'compact';
  className?: string;
  secondaryClassName?: string;
};

export function BrandTitle({
  variant = 'report',
  className,
  secondaryClassName,
}: BrandTitleProps) {
  const { primary, secondary } = getLogoLines();

  if (variant === 'stacked') {
    return (
      <h1 className={cn('font-black tracking-tight uppercase leading-none', className)}>
        {primary}
        {secondary ? (
          <>
            <br />
            <span className={cn('text-slate-500', secondaryClassName)}>{secondary}</span>
          </>
        ) : null}
      </h1>
    );
  }

  if (variant === 'compact') {
    return (
      <span className={cn('font-black uppercase tracking-widest', className)}>
        {clientConfig.LOGO_TEXT}
      </span>
    );
  }

  return (
    <h1 className={cn('report-title', className)}>{clientConfig.BUSINESS_NAME}</h1>
  );
}
