import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from 'recharts';
import { ChartCard } from './ChartCard';
import { useSalesPurchasesTrend, type SalesPurchasesTrendRow } from '@/lib/api/dashboard-analytics';
import { formatPKR } from '@/lib/format';
import { chartGridColor, chartLegendProps, chartMargin, chartTextColor, chartTooltipStyle, formatAxisDate, formatAxisNumber } from './chart-utils';

interface SalesPurchasesTrendChartProps {
  startDate: string;
  endDate: string;
}

function hasTrendData(data: SalesPurchasesTrendRow[]) {
  return data.some(row => Number(row.sales_amount) > 0 || Number(row.purchases_amount) > 0);
}

export function SalesPurchasesTrendChart({ startDate, endDate }: SalesPurchasesTrendChartProps) {
  const { data = [], isLoading, isError, error, refetch } = useSalesPurchasesTrend(startDate, endDate);

  return (
    <ChartCard
      title="Sales vs Purchases"
      subtitle="Daily trend"
      isLoading={isLoading}
      isError={isError}
      errorMessage={error?.message}
      onRetry={() => refetch()}
      isEmpty={!isLoading && !isError && !hasTrendData(data)}
    >
      <ResponsiveContainer width="100%" height={220}>
        <LineChart data={data} margin={chartMargin}>
          <CartesianGrid strokeDasharray="3 3" stroke={chartGridColor} />
          <XAxis
            dataKey="tx_date"
            tickFormatter={formatAxisDate}
            tick={{ fontSize: 10, fill: chartTextColor }}
            axisLine={false}
            tickLine={false}
          />
          <YAxis
            width={42}
            tick={{ fontSize: 10, fill: chartTextColor }}
            axisLine={false}
            tickLine={false}
            tickFormatter={formatAxisNumber}
          />
          <Tooltip
            formatter={(value: number, name: string) => [formatPKR(value), name]}
            labelFormatter={(label) => formatAxisDate(String(label))}
            contentStyle={chartTooltipStyle}
          />
          <Legend {...chartLegendProps} />
          <Line
            type="monotone"
            name="Sales"
            dataKey="sales_amount"
            stroke="#0f766e"
            strokeWidth={2}
            dot={false}
            activeDot={{ r: 4 }}
          />
          <Line
            type="monotone"
            name="Purchases"
            dataKey="purchases_amount"
            stroke="#64748B"
            strokeWidth={2}
            dot={false}
            activeDot={{ r: 4 }}
          />
        </LineChart>
      </ResponsiveContainer>
    </ChartCard>
  );
}
