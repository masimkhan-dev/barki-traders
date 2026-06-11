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
import { useStockByFuel } from '@/lib/api/dashboard-analytics';
import { formatNumber, formatPKR } from '@/lib/format';
import { chartGridColor, chartMargin, chartTextColor, chartTooltipStyle, compactFuelLabel } from './chart-utils';

export function StockByFuelChart() {
  const { data = [], isLoading, isError, error, refetch } = useStockByFuel();

  const chartData = data.map(row => ({
    ...row,
    label: compactFuelLabel(row.fuel_name),
    fullName: row.fuel_name,
  }));

  const isEmpty = !isLoading && !isError && chartData.every(row => Number(row.quantity) === 0);

  return (
    <ChartCard
      title="Current Stock by Fuel"
      subtitle="Snapshot at weighted avg cost"
      isLoading={isLoading}
      isError={isError}
      errorMessage={error?.message}
      onRetry={() => refetch()}
      isEmpty={isEmpty}
      emptyMessage="No active fuel stock"
    >
      <ResponsiveContainer width="100%" height={220}>
        <BarChart data={chartData} layout="vertical" margin={chartMargin}>
          <CartesianGrid strokeDasharray="3 3" stroke={chartGridColor} horizontal={false} />
          <XAxis type="number" tick={{ fontSize: 10, fill: chartTextColor }} axisLine={false} tickLine={false} />
          <YAxis
            type="category"
            dataKey="label"
            width={88}
            tick={{ fontSize: 10, fill: chartTextColor, fontWeight: 600 }}
            axisLine={false}
            tickLine={false}
          />
          <Tooltip
            labelFormatter={(_label, payload) => payload?.[0]?.payload?.fullName ?? _label}
            formatter={(value: number, name: string) => {
              if (name === 'quantity') return [formatNumber(value), 'Quantity'];
              return [formatPKR(value), 'Stock Value'];
            }}
            contentStyle={chartTooltipStyle}
          />
          <Bar dataKey="quantity" fill="#0f766e" radius={[0, 4, 4, 0]} name="quantity" />
        </BarChart>
      </ResponsiveContainer>
    </ChartCard>
  );
}
