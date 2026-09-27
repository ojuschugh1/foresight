# frozen_string_literal: true

module Foresight
  OriginResult = Struct.new(:start, :model, :mase_scale, :mae, :rmse, :mase,
                            :scaled_pinball, :scaled_pinball_zero, :scaled_pinball_nonzero,
                            :zero_held_out, :nonzero_held_out,
                            :coverage, :covered, :lead_time_hit, keyword_init: true)
  Backtest = Struct.new(:origins, :excluded_origins, :zero_scale_origins, :held_out,
                        :zero_held_out, :nonzero_held_out,
                        :mae, :rmse, :mase, :scaled_pinball, :scaled_pinball_zero, :scaled_pinball_nonzero,
                        :coverage, :lead_time_coverage, :covered, :lead_time_hits, keyword_init: true)

  class Backtester
    def initialize(**options)
      @options = Options.backtest(options)
      @horizon = @options[:horizon]
      @levels = @options[:levels]
      @forecaster = Forecaster.new(@options.merge(count: @horizon).freeze)
    end

    def run(series)
      series = Series.parse(series, keys_required: true)
      check_length(series.size)
      prefixes = origin_positions(series.size).to_h { |position| [position, series.prefix(position)] }
      kept = prefixes.reject { |_, prefix| @options[:model].nil? && prefix.exact.all?(&:zero?) }
      results = kept.map { |position, prefix| origin_result(series, position, prefix) }
      aggregate(results, prefixes.size - kept.size)
    end

    private

    def check_length(size)
      origins = @options[:origins]
      step = @options[:step]
      required = minimum_history + @horizon + step * (origins - 1)
      return if size >= required

      raise InputError, "the backtest needs at least #{required} observations for horizon #{@horizon}, " \
                        "#{origins} origins and step #{step}, got #{size}"
    end

    def minimum_history
      name = @options[:model]
      model_minimum = name ? MODELS.fetch(name).minimum_history(@options) : Selector::MINIMUM_HISTORY
      [2, strategy_minimum(name || :ses), model_minimum].max
    end

    def strategy_minimum(name)
      model_class = MODELS.fetch(name)
      if @options[:strategy] == :conformal
        ConformalStrategy.minimum_history(model_class, @options, @horizon)
      elsif Forecaster::SMOOTH_MODELS.include?(name)
        GaussianStrategy.minimum_history(model_class, @options)
      else
        CompoundStrategy.minimum_history(model_class, @options)
      end
    end

    def origin_positions(size)
      origins = @options[:origins]
      (0...origins).map { |origin| size - @horizon - @options[:step] * (origins - 1 - origin) }
    end

    def origin_result(series, position, prefix)
      result = @forecaster.call(prefix)
      actual = series.values[position, @horizon]
      scale = Metrics.scale(prefix.values)
      mae = Metrics.mae(actual, result.forecast)
      zeros = actual.count(&:zero?)
      covered = by_level { |level| actual.zip(result.quantiles[level]).count { |value, quantile| value <= quantile } }
      total = actual.inject(0.0, :+)
      OriginResult.new(start: series.label(position), model: result.model, mase_scale: scale, mae: mae,
                       rmse: Metrics.rmse(actual, result.forecast), mase: scaled(mae, scale),
                       **scaled_pinball(result.quantiles, actual, scale),
                       zero_held_out: zeros, nonzero_held_out: @horizon - zeros,
                       coverage: covered.transform_values { |count| count.fdiv(@horizon) }, covered: covered,
                       lead_time_hit: by_level { |level| total <= result.lead_time_quantiles[level] })
    end

    def scaled_pinball(quantiles, actual, scale)
      whole = {}
      zero = {}
      nonzero = {}
      @levels.each do |level|
        sums = pinball_sums(level, quantiles[level], actual)
        whole[level], zero[level], nonzero[level] = sums.map { |sum| scaled(sum / @horizon, scale) }
      end
      { scaled_pinball: whole, scaled_pinball_zero: zero, scaled_pinball_nonzero: nonzero }
    end

    def pinball_sums(level, quantiles, actual)
      whole = zero = nonzero = 0.0
      actual.each_with_index do |value, period|
        loss = Metrics.pinball(level, quantiles[period], value)
        whole += loss
        if value.zero?
          zero += loss
        else
          nonzero += loss
        end
      end
      [whole, zero, nonzero]
    end

    def scaled(value, scale)
      scale.zero? ? nil : value / scale
    end

    def aggregate(results, excluded)
      held_out = @horizon * results.size
      covered = by_level { |level| results.sum { |result| result.covered[level] } }
      hits = by_level { |level| results.count { |result| result.lead_time_hit[level] } }
      Backtest.new(origins: results, excluded_origins: excluded,
                   zero_scale_origins: results.count { |result| result.mase_scale.zero? }, held_out: held_out,
                   zero_held_out: results.sum(&:zero_held_out), nonzero_held_out: results.sum(&:nonzero_held_out),
                   mae: mean(results.map(&:mae)), rmse: mean(results.map(&:rmse)), mase: mean(results.map(&:mase)),
                   scaled_pinball: level_means(results, &:scaled_pinball),
                   scaled_pinball_zero: level_means(results, &:scaled_pinball_zero),
                   scaled_pinball_nonzero: level_means(results, &:scaled_pinball_nonzero),
                   coverage: covered.transform_values { |count| proportion(count, held_out) },
                   lead_time_coverage: hits.transform_values { |count| proportion(count, results.size) },
                   covered: covered, lead_time_hits: hits)
    end

    def level_means(results)
      by_level { |level| mean(results.map { |result| yield(result)[level] }) }
    end

    def mean(values)
      present = values.compact
      return if present.empty?

      present.inject(:+) / present.size
    end

    def proportion(count, total)
      count.fdiv(total) if total.positive?
    end

    def by_level
      @levels.to_h { |level| [level, yield(level)] }
    end
  end
end
