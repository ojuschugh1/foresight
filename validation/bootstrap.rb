# frozen_string_literal: true

module Bootstrap
  STRATEGIES = %w[distribution conformal].freeze
  STATISTICS = %w[coverage lead_time_coverage scaled_pinball].freeze
  DIFFERENCES = %w[coverage_error lead_time_coverage_error scaled_pinball coverage lead_time_coverage].freeze
  BOUNDS = [Rational(25, 1000), Rational(975, 1000)].freeze

  class << self
    def intervals(records, levels:, resamples:, seed:)
      samples = records.size < 2 ? [] : resample(records, levels, resamples, Random.new(seed))
      pooled = STRATEGIES.to_h do |strategy|
        [strategy, levels.to_h { |level| [level, intervals_at(samples, strategy, level, STATISTICS)] }]
      end
      paired = levels.to_h { |level| [level, intervals_at(samples, "difference", level, DIFFERENCES)] }
      pooled.merge("difference" => paired)
    end

    def statistics(records, levels)
      held_out = records.sum { |record| record["held_out"] }
      origins = records.sum { |record| record["origins"] }
      pooled = STRATEGIES.to_h do |strategy|
        [strategy, levels.to_h { |level| [level, pooled_statistics(records, strategy, level, held_out, origins)] }]
      end
      paired = levels.to_h do |level|
        [level, differences(pooled["distribution"][level], pooled["conformal"][level], level)]
      end
      pooled.merge("difference" => paired)
    end

    def differences(distribution, conformal, level)
      {
        "coverage_error" => error_difference(distribution, conformal, "coverage", level),
        "lead_time_coverage_error" => error_difference(distribution, conformal, "lead_time_coverage", level),
        "scaled_pinball" => difference(distribution, conformal, "scaled_pinball"),
        "coverage" => difference(distribution, conformal, "coverage"),
        "lead_time_coverage" => difference(distribution, conformal, "lead_time_coverage")
      }
    end

    private

    def resample(records, levels, resamples, rng)
      Array.new(resamples) do
        draw = Array.new(records.size) { records[rng.rand(records.size)] }
        statistics(draw, levels)
      end
    end

    def intervals_at(samples, name, level, statistics)
      statistics.to_h do |statistic|
        ["#{statistic}_interval", interval(samples.map { |sample| sample[name][level][statistic] })]
      end
    end

    def interval(values)
      return if values.empty? || values.include?(nil)

      sorted = values.sort
      BOUNDS.map { |bound| sorted[(bound * sorted.size).ceil - 1] }
    end

    def pooled_statistics(records, strategy, level, held_out, origins)
      entries = records.map { |record| record[strategy]["levels"].find { |entry| entry["level"] == level } }
      losses = entries.filter_map { |entry| entry["scaled_pinball"] }
      {
        "coverage" => ratio(entries.sum { |entry| entry["covered"] }, held_out),
        "lead_time_coverage" => ratio(entries.sum { |entry| entry["lead_time_hits"] }, origins),
        "scaled_pinball" => losses.empty? ? nil : losses.inject(:+) / losses.size
      }
    end

    def ratio(count, total)
      count.fdiv(total) unless total.zero?
    end

    def difference(distribution, conformal, statistic)
      distribution[statistic] - conformal[statistic] if distribution[statistic] && conformal[statistic]
    end

    def error_difference(distribution, conformal, statistic, level)
      return unless distribution[statistic] && conformal[statistic]

      (distribution[statistic] - level).abs - (conformal[statistic] - level).abs
    end
  end
end
