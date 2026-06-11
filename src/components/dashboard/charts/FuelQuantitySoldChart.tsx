import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from 'recharts';
import { ChartCard } from './ChartCard';
import { useFuelQuantitySold } from '@/lib/api/dashboard-analytics';
import { formatNumber, formatPKR } from '@/lib/format';
import { chartGridColor, chartMargin, chartTextColor, chartTooltipStyle, compactFuelLabel } from './chart-utils';

interface FuelQuantitySoldChartProps {
  startDate: string;
  endDate: string;
}

export function FuelQuantitySoldChart({ startDate, endDate }: FuelQuantitySoldChartProps) {
  const { data = [], isLoading, isError, error, refetch } = useFuelQuantitySold(startDate, endDate);

  const chartData = data.map(row => ({
    ...row,
    label: compactFuelLabel(row.fuel_name),
    fullName: row.fuel_name,
  }));

  return (
    <ChartCard
      title="Fuel Quantity Sold"
      subtitle="Breakdown by fuel type"
      isLoading={isLoading}
      isError={isError}
      errorMessage={error?.message}
      onRetry={() => refetch()}
      isEmpty={!isLoading && !isError && chartData.length === 0}
    >
      <ResponsiveContainer width="100%" height={220}>
        <BarChart data={chartData} margin={{ ...chartMargin, bottom: 8 }}>
          <CartesianGrid strokeDasharray="3 3" stroke={chartGridColor} />
          <XAxis
            dataKey="label"
            interval={0}
            tick={{ fontSize: 10, fill: chartTextColor, fontWeight: 600 }}
            axisLine={false}
            tickLine={false}
          />
          <YAxis
            tick={{ fontSize: 10, fill: chartTextColor }}
            axisLine={false}
            tickLine={false}
            tickFormatter={(v) => formatNumber(v)}
          />
          <Tooltip
            labelFormatter={(_label, payload) => payload?.[0]?.payload?.fullName ?? _label}
            formatter={(value: number, name: string) => {
              if (name === 'quantity_sold') return [formatNumber(value), 'Qty Sold'];
              return [formatPKR(value), 'Sales Amount'];
            }}
            contentStyle={chartTooltipStyle}
          />
          <Bar dataKey="quantity_sold" fill="#0f766e" radius={[4, 4, 0, 0]} name="quantity_sold" />
        </BarChart>
      </ResponsiveContainer>
    </ChartCard>
  );
}
