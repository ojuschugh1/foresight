# frozen_string_literal: true

module Foresight
  class Naive
    attr_reader :residuals

    def self.minimum_history(_options)
      1
    end

    def initialize(values, _options)
      @forecast = values.last
      @residuals = (1...values.size).map { |index| values[index] - values[index - 1] }
    end

    def forecast(horizon)
      Array.new(horizon, @forecast)
    end

    def step_factors(horizon)
      (1..horizon).to_a
    end

    def total_factor(horizon)
      horizon * (horizon + 1) * (2 * horizon + 1) / 6
    end
  end
end
