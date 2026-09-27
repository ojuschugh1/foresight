# frozen_string_literal: true

module Foresight
  class SES
    attr_reader :alpha, :residuals

    def self.minimum_history(_options)
      1
    end

    def initialize(values, _options)
      @alpha = Smoothing.golden_section(values, 0.01, 0.99)
      @forecast, fitted = Smoothing.run(values, alpha)
      @residuals = (1...values.size).map { |index| values[index] - fitted[index] }
    end

    def forecast(horizon)
      Array.new(horizon, @forecast)
    end

    def step_factors(horizon)
      Array.new(horizon) { |index| 1 + index * alpha * alpha }
    end

    def total_factor(horizon)
      (0...horizon).sum { |index| (1 + index * alpha)**2 }
    end
  end
end
