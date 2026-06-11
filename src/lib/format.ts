import { clientConfig } from '@/lib/client-config';

/**
 * Format a number as Pakistani Rupees
 */
export function formatPKR(amount: number | null | undefined): string {
  if (amount === null || amount === undefined) return `${clientConfig.CURRENCY} 0`;
  
  return new Intl.NumberFormat(clientConfig.LOCALE, {
    style: 'currency',
    currency: clientConfig.CURRENCY,
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  }).format(amount);
}

/**
 * Format large values compactly for dashboard cards and chart axes.
 */
export function formatCompactNumber(num: number | null | undefined): string {
  if (num === null || num === undefined) return '0';

  const value = Number(num);
  const absValue = Math.abs(value);

  if (absValue >= 1_000_000) {
    return `${(value / 1_000_000).toFixed(absValue >= 10_000_000 ? 1 : 2).replace(/\.0+$/, '')}M`;
  }

  if (absValue >= 1_000) {
    return `${(value / 1_000).toFixed(absValue >= 10_000 ? 0 : 1).replace(/\.0+$/, '')}K`;
  }

  return formatNumber(value);
}

export function formatCompactPKR(amount: number | null | undefined): string {
  return `${clientConfig.CURRENCY} ${formatCompactNumber(amount)}`;
}

/**
 * Format a number with commas (Pakistani number system)
 */
export function formatNumber(num: number | null | undefined): string {
  if (num === null || num === undefined) return '0';
  
  return new Intl.NumberFormat(clientConfig.LOCALE).format(num);
}

/**
 * Format a date for display
 */
export function formatDate(date: string | Date | null | undefined): string {
  if (!date) return '-';
  
  const d = typeof date === 'string' ? new Date(date) : date;
  
  return new Intl.DateTimeFormat(clientConfig.LOCALE, {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
  }).format(d);
}

/**
 * Format a date for input fields
 */
export function formatDateInput(date: Date | null): string {
  if (!date) return '';
  return date.toISOString().split('T')[0];
}

/**
 * Format a date and time for display
 */
export function formatDateTime(date: string | Date | null | undefined): string {
  if (!date) return '-';
  
  const d = typeof date === 'string' ? new Date(date) : date;
  
  return new Intl.DateTimeFormat(clientConfig.LOCALE, {
    day: '2-digit',
    month: 'short',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  }).format(d);
}

/**
 * Get relative time (e.g., "2 hours ago")
 */
export function getRelativeTime(date: string | Date): string {
  const d = typeof date === 'string' ? new Date(date) : date;
  const now = new Date();
  const diffInSeconds = Math.floor((now.getTime() - d.getTime()) / 1000);
  
  if (diffInSeconds < 60) return 'Just now';
  if (diffInSeconds < 3600) return `${Math.floor(diffInSeconds / 60)} min ago`;
  if (diffInSeconds < 86400) return `${Math.floor(diffInSeconds / 3600)} hours ago`;
  if (diffInSeconds < 604800) return `${Math.floor(diffInSeconds / 86400)} days ago`;
  
  return formatDate(d);
}

/**
 * Format quantity with unit
 */
export function formatQuantity(quantity: number, unit: string = 'Liters'): string {
  return `${formatNumber(quantity)} ${unit}`;
}
