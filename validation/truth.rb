# frozen_string_literal: true

module Truth
  BISECTION_WIDTH = 1e-12

  Quantiles = Struct.new(:step_quantile, :total_quantile, :step_probability, :total_probability,
                         keyword_init: true)

  class << self
    def quantiles(process, horizon:, levels:)
      if process["kind"] == "gaussian"
        gaussian_quantiles(process["mean"], process["sd"], horizon, levels)
      else
        bernoulli_quantiles(process["occurrence"], process["sizes"], horizon, levels)
      end
    end

    def step_distribution(occurrence, sizes)
      chance = Rational(occurrence)
      total_weight = sizes.sum { |_size, weight| weight }
      masses = Hash.new(0r)
      masses[0] += 1 - chance
      sizes.each { |size, weight| masses[size] += chance * weight / total_weight }
      masses.sort.to_h
    end

    def total_distribution(step, horizon)
      (1..horizon).inject({ 0 => 1r }) { |totals, _period| convolve(totals, step) }
    end

    def normal_quantile(level)
      low = -40.0
      high = 40.0
      while high - low > BISECTION_WIDTH
        middle = (low + high) / 2
        if 0.5 * Math.erfc(-middle / Math.sqrt(2)) < level
          low = middle
        else
          high = middle
        end
      end
      high
    end

    private

    def bernoulli_quantiles(occurrence, sizes, horizon, levels)
      step = step_distribution(occurrence, sizes)
      total = total_distribution(step, horizon)
      levels.to_h do |level|
        step_quantile = quantile(step, level)
        total_quantile = quantile(total, level)
        [level, Quantiles.new(step_quantile: step_quantile, total_quantile: total_quantile,
                              step_probability: cdf(step, step_quantile),
                              total_probability: cdf(total, total_quantile))]
      end
    end

    def gaussian_quantiles(mean, sd, horizon, levels)
      variance = horizon * sd * sd
      levels.to_h do |level|
        deviate = normal_quantile(level)
        [level, Quantiles.new(step_quantile: [0.0, mean + sd * deviate].max,
                              total_quantile: horizon * mean + Math.sqrt(variance) * deviate)]
      end
    end

    def convolve(totals, step)
      sums = Hash.new(0r)
      totals.each { |total, mass| step.each { |demand, chance| sums[total + demand] += mass * chance } }
      sums.sort.to_h
    end

    def quantile(distribution, level)
      distribution.keys.select { |value| cdf(distribution, value) >= level.to_r }.min
    end

    def cdf(distribution, value)
      distribution.sum(0r) { |outcome, mass| outcome <= value ? mass : 0r }
    end
  end
end
