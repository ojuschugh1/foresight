# frozen_string_literal: true

module Foresight
  class CompoundStrategy
    def self.minimum_history(model_class, options)
      model_class.minimum_history(options)
    end

    def initialize(model, horizon:, levels:, paths:, seed:)
      @probability = model.probability
      @sizes = model.sizes
      @horizon = horizon
      @levels = levels
      @simulator = Simulator.new(probability: @probability, sizes: @sizes, horizon: horizon, paths: paths, seed: seed)
    end

    def quantiles
      @levels.to_h { |level| [level, Array.new(@horizon, step_quantile(level))] }
    end

    def lead_time_quantiles
      totals = @simulator.totals.sort
      @levels.to_h { |level| [level, EmpiricalQuantile.at(totals, level)] }
    end

    private

    def step_quantile(level)
      probability = @probability.to_r
      return 0.0 if @sizes.empty? || level.to_r <= 1 - probability

      @sizes[((level.to_r - (1 - probability)) * @sizes.size / probability).ceil - 1]
    end
  end
end
