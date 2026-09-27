# frozen_string_literal: true

module Foresight
  class GaussianStrategy
    def self.minimum_history(model_class, options)
      model_class.minimum_history(options) + 1
    end

    def initialize(model, horizon:, levels:)
      residuals = model.residuals
      variance = residuals.sum { |residual| residual * residual } / residuals.size
      @sigma = Math.sqrt(variance)
      @forecast = model.forecast(horizon)
      @step_factors = model.step_factors(horizon)
      @total_factor = model.total_factor(horizon)
      @deviates = deviates(levels)
    end

    def quantiles
      @deviates.transform_values do |deviate|
        @forecast.zip(@step_factors).map { |value, factor| [0.0, value + deviate * @sigma * Math.sqrt(factor)].max }
      end
    end

    def lead_time_quantiles
      total = @forecast.sum
      @deviates.transform_values { |deviate| [0.0, total + deviate * @sigma * Math.sqrt(@total_factor)].max }
    end

    private

    def deviates(levels)
      largest = -Float::INFINITY
      levels.to_h do |level|
        # The running maximum absorbs last-bit disagreements between the two AS 241 approximations
        largest = [largest, Normal.quantile(level)].max
        [level, largest]
      end
    end
  end
end
