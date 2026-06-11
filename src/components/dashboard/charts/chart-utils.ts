import { format, parseISO } from 'date-fns';
import { formatCompactNumber } from '@/lib/format';

export function formatAxisDate(value: string) {
  try {
    return format(parseISO(value), 'd MMM');
  } catch {
    return value;
  }
}

export function formatAxisNumber(value: number | string) {
  return formatCompactNumber(Number(value));
}

export function compactFuelLabel(name: string) {
  return name
    .replace(/\bReliance\b/gi, 'Rel.')
    .replace(/\bDiesel MHO\b/gi, 'MHO')
    .replace(/\s+/g, ' ')
    .trim();
}

export const chartGridColor = '#F4F4F5';
export const chartTextColor = '#71717A';
export const chartTooltipStyle = {
  fontSize: 11,
  borderRadius: 8,
  border: '1px solid #E4E4E7',
} as const;

/** Shared Recharts legend — spaced labels via `name` on series, not formatters. */
export const chartLegendProps = {
  verticalAlign: 'bottom' as const,
  align: 'center' as const,
  iconType: 'circle' as const,
  iconSize: 8,
  wrapperStyle: {
    fontSize: 10,
    fontWeight: 700,
    textTransform: 'uppercase' as const,
    paddingTop: 12,
    lineHeight: '20px',
    letterSpacing: '0.04em',
  },
};

export const chartMargin = { top: 8, right: 14, left: 8, bottom: 4 };
