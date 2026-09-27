# frozen_string_literal: true

module Foresight
  EvaluationReport = Struct.new(:classes, :series, :excluded_series, :levels, keyword_init: true)
  ClassSummary = Struct.new(:demand_class, :series_count, :excluded_origins, :zero_scale_origins, :held_out,
                            :zero_held_out, :nonzero_held_out, :mae, :rmse, :mase,
                            :scaled_pinball, :scaled_pinball_zero, :scaled_pinball_nonzero,
                            :coverage, :lead_time_coverage, keyword_init: true)
  SeriesEntry = Struct.new(:index, :demand_class, :backtest, keyword_init: true)

  class EvaluationReport
    DEMAND_CLASSES = %i[smooth erratic intermittent lumpy].freeze

    class << self
      def aggregate(entries, horizon:, levels:)
        classes = DEMAND_CLASSES.to_h do |demand_class|
          backtests = entries.select { |entry| entry.demand_class == demand_class }.map(&:backtest)
          [demand_class, summary(demand_class, backtests, levels)]
        end
        new(classes: classes, series: entries, excluded_series: 0, levels: levels)
      end

      private

      def summary(demand_class, backtests, levels)
        held_out = backtests.sum(&:held_out)
        origins = backtests.sum { |backtest| backtest.origins.size }
        ClassSummary.new(demand_class: demand_class, series_count: backtests.size,
                         excluded_origins: backtests.sum(&:excluded_origins),
                         zero_scale_origins: backtests.sum(&:zero_scale_origins), held_out: held_out,
                         zero_held_out: backtests.sum(&:zero_held_out),
                         nonzero_held_out: backtests.sum(&:nonzero_held_out),
                         mae: mean(backtests.map(&:mae)), rmse: mean(backtests.map(&:rmse)),
                         mase: mean(backtests.map(&:mase)),
                         scaled_pinball: level_means(backtests, levels, &:scaled_pinball),
                         scaled_pinball_zero: level_means(backtests, levels, &:scaled_pinball_zero),
                         scaled_pinball_nonzero: level_means(backtests, levels, &:scaled_pinball_nonzero),
                         coverage: pooled(backtests, levels, held_out, &:covered),
                         lead_time_coverage: pooled(backtests, levels, origins, &:lead_time_hits))
      end

      def level_means(backtests, levels)
        levels.to_h { |level| [level, mean(backtests.map { |backtest| yield(backtest)[level] })] }
      end

      def pooled(backtests, levels, total)
        levels.to_h { |level| [level, proportion(backtests.sum { |backtest| yield(backtest)[level] }, total)] }
      end

      def mean(values)
        present = values.compact
        return if present.empty?

        present.inject(:+) / present.size
      end

      def proportion(count, total)
        count.fdiv(total) if total.positive?
      end
    end
  end
end
