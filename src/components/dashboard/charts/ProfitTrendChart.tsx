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
import { useProfitTrend, type ProfitTrendRow } from '@/lib/api/dashboard-analytics';
import { formatPKR } from '@/lib/format';
import { chartGridColor, chartLegendProps, chartMargin, chartTextColor, chartTooltipStyle, formatAxisDate, formatAxisNumber } from './chart-utils';

interface ProfitTrendChartProps {
  startDate: string;
  endDate: string;
}

function hasProfitData(data: ProfitTrendRow[]) {
  return data.some(
    row => Number(row.income) > 0 || Number(row.expense) > 0 || Number(row.gross_profit) !== 0
  );
}

export function ProfitTrendChart({ startDate, endDate }: ProfitTrendChartProps) {
  const { data = [], isLoading, isError, error, refetch } = useProfitTrend(startDate, endDate);

  return (
    <ChartCard
      title="Profit Trend"
      subtitle="Daily income, expense & gross profit"
      isLoading={isLoading}
      isError={isError}
      errorMessage={error?.message}
      onRetry={() => refetch()}
      isEmpty={!isLoading && !isError && !hasProfitData(data)}
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
          <Line type="monotone" name="Income" dataKey="income" stroke="#16a34a" strokeWidth={2} dot={false} />
          <Line type="monotone" name="Expense" dataKey="expense" stroke="#dc2626" strokeWidth={2} dot={false} />
          <Line type="monotone" name="Gross Profit" dataKey="gross_profit" stroke="#0f766e" strokeWidth={2} strokeDasharray="4 4" dot={false} />
        </LineChart>
      </ResponsiveContainer>
    </ChartCard>
  );
}
