# frozen_string_literal: true

module Foresight
  class ConformalStrategy
    def self.minimum_history(model_class, options, horizon)
      model_class.minimum_history(options) + options[:windows] * horizon
    end

    def initialize(model_class, values, options, horizon:, levels:, point:)
      windows = options[:windows]
      window_errors = []
      total_errors = []
      windows.times do |window|
        start = values.size - windows * horizon + window * horizon
        actual = values[start, horizon]
        forecast = model_class.new(values.first(start), options).forecast(horizon)
        window_errors << actual.zip(forecast).map { |value, predicted| (value - predicted).abs }
        total_errors << (actual.sum - forecast.sum).abs
      end
      @levels = levels
      @steps = point.zip(window_errors.transpose).map { |value, errors| spread(value, errors) }
      @totals = spread(point.sum, total_errors)
    end

    def quantiles
      @levels.to_h { |level| [level, @steps.map { |sorted| quantile(sorted, level) }] }
    end

    def lead_time_quantiles
      @levels.to_h { |level| [level, quantile(@totals, level)] }
    end

    private

    def spread(center, errors)
      errors.flat_map { |error| [center - error, center + error] }.sort
    end

    def quantile(sorted, level)
      [0.0, EmpiricalQuantile.at(sorted, level)].max
    end
  end
end
