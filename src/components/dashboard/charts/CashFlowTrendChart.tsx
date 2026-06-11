import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer,
} from 'recharts';
import { ChartCard } from './ChartCard';
import { useCashFlowTrend, type CashFlowTrendRow } from '@/lib/api/dashboard-analytics';
import { formatPKR } from '@/lib/format';
import { chartGridColor, chartLegendProps, chartMargin, chartTextColor, chartTooltipStyle, formatAxisDate, formatAxisNumber } from './chart-utils';

interface CashFlowTrendChartProps {
  startDate: string;
  endDate: string;
}

function hasCashFlowData(data: CashFlowTrendRow[]) {
  return data.some(
    row => Number(row.cash_in) > 0 || Number(row.cash_out) > 0 || Number(row.net_cash_flow) !== 0
  );
}

export function CashFlowTrendChart({ startDate, endDate }: CashFlowTrendChartProps) {
  const { data = [], isLoading, isError, error, refetch } = useCashFlowTrend(startDate, endDate);

  return (
    <ChartCard
      title="Cash In vs Cash Out"
      subtitle="Daily cash & bank movement"
      isLoading={isLoading}
      isError={isError}
      errorMessage={error?.message}
      onRetry={() => refetch()}
      isEmpty={!isLoading && !isError && !hasCashFlowData(data)}
    >
      <ResponsiveContainer width="100%" height={220}>
        <AreaChart data={data} margin={chartMargin}>
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
          <Area type="monotone" name="Cash In" dataKey="cash_in" stackId="1" stroke="#16a34a" fill="#dcfce7" strokeWidth={2} />
          <Area type="monotone" name="Cash Out" dataKey="cash_out" stackId="2" stroke="#dc2626" fill="#fee2e2" strokeWidth={2} />
          <Area type="monotone" name="Net Flow" dataKey="net_cash_flow" stroke="#0f766e" fill="transparent" strokeWidth={2} strokeDasharray="4 4" />
        </AreaChart>
      </ResponsiveContainer>
    </ChartCard>
  );
}
