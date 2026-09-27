# frozen_string_literal: true

module Oracles
  ADI_CUTOFF = 1.32r
  CV_SQUARED_CUTOFF = 0.49r
  GOLDEN_RATIO = (1 + Math.sqrt(5)) / 2
  SES_LOWER = 0.01
  SES_UPPER = 0.99
  SES_WIDTH = 1e-12

  module_function

  def classification(observations)
    demand_sizes = observations.reject { |observation| observation == 0 }.map { |size| Rational(size) }
    adi = Rational(observations.size, demand_sizes.size)
    mean = demand_sizes.inject(:+) / demand_sizes.size
    variance = demand_sizes.map { |size| (size - mean) * (size - mean) }.inject(:+) / demand_sizes.size
    cv_squared = variance / (mean * mean)
    { demand_class: demand_class(adi, cv_squared), adi: adi, cv_squared: cv_squared }
  end

  def demand_class(adi, cv_squared)
    {
      smooth: adi < ADI_CUTOFF && cv_squared < CV_SQUARED_CUTOFF,
      erratic: adi < ADI_CUTOFF && cv_squared >= CV_SQUARED_CUTOFF,
      intermittent: adi >= ADI_CUTOFF && cv_squared < CV_SQUARED_CUTOFF,
      lumpy: adi >= ADI_CUTOFF && cv_squared >= CV_SQUARED_CUTOFF
    }.key(true)
  end

  def point_forecasts(model, values, options, horizon)
    if model == :seasonal_naive
      season_length = options[:season_length]
      return (1..horizon).map { |period| values[values.size - season_length + (period - 1) % season_length] }
    end

    Array.new(horizon, point_forecast(model, values, options))
  end

  def point_forecast(model, values, options)
    case model
    when :naive then values.last
    when :ses then smoothed(values, ses_alpha(values))
    when :croston_classic then croston(values, options[:alpha].to_f)
    when :croston_sba
      alpha = options[:alpha].to_f
      croston(values, alpha) * (1 - alpha / 2)
    when :tsb then tsb(values, options[:alpha_d].to_f, options[:alpha_p].to_f)
    end
  end

  def smoothed(values, alpha)
    return values.first if values.size == 1

    values.inject(values.first) { |level, value| alpha * value + (1 - alpha) * level }
  end

  def one_step_errors(values, alpha)
    level = values.first
    values.each_cons(2).map do |previous, value|
      level = alpha * previous + (1 - alpha) * level
      value - level
    end
  end

  def one_step_sse(values, alpha)
    one_step_errors(values, alpha).inject(0.0) { |sum, error| sum + error * error }
  end

  def ses_alpha(values)
    low = SES_LOWER
    high = SES_UPPER
    points = [high - (high - low) / GOLDEN_RATIO, low + (high - low) / GOLDEN_RATIO]
    sums = points.map { |point| one_step_sse(values, point) }
    until high - low < SES_WIDTH || sums[0] == sums[1]
      if sums[0] < sums[1]
        high = points[1]
        points = [high - (high - low) / GOLDEN_RATIO, points[0]]
        sums = [one_step_sse(values, points[0]), sums[0]]
      else
        low = points[0]
        points = [points[1], low + (high - low) / GOLDEN_RATIO]
        sums = [sums[1], one_step_sse(values, points[1])]
      end
    end
    (low + high) / 2
  end

  def croston(values, alpha)
    positions = (1..values.size).select { |position| values[position - 1] != 0 }
    return 0.0 if positions.empty?

    sizes = positions.map { |position| values[position - 1] }
    intervals = positions.each_with_index.map do |position, index|
      index.zero? ? position.to_f : (position - positions[index - 1]).to_f
    end
    smoothed(sizes, alpha) / smoothed(intervals, alpha)
  end

  def tsb(values, alpha_d, alpha_p)
    sizes = values.reject { |value| value == 0 }
    return 0.0 if sizes.empty?

    indicators = values.map { |value| value == 0 ? 0.0 : 1.0 }
    smoothed(indicators, alpha_p) * smoothed(sizes, alpha_d)
  end

  def normal_quantile(level)
    return -normal_quantile(1 - level) if level > 0.5

    low = -40.0
    high = 0.0
    loop do
      middle = (low + high) / 2
      return middle if middle == low || middle == high

      if 0.5 * Math.erfc(-middle / Math.sqrt(2)) < level
        low = middle
      else
        high = middle
      end
    end
  end

  def gaussian_quantiles(model, values, options, horizon, levels)
    season_length = options[:season_length]
    alpha = ses_alpha(values) if model == :ses
    forecasts = point_forecasts(model, values, options, horizon)
    errors = residuals(model, values, season_length, alpha)
    sigma = Math.sqrt(errors.sum { |error| error * error } / errors.size)
    covariance = error_covariance(model, horizon, season_length: season_length, alpha: alpha)
    variances = covariance.each_with_index.map { |row, index| row[index] }
    total = covariance.sum(&:sum)
    levels.to_h do |level|
      deviate = normal_quantile(level)
      steps = forecasts.zip(variances).map { |forecast, variance| forecast + deviate * sigma * Math.sqrt(variance) }
      [level, [steps, forecasts.sum + deviate * sigma * Math.sqrt(total)]]
    end
  end

  def residuals(model, values, season_length, alpha)
    case model
    when :naive then values.each_cons(2).map { |previous, value| value - previous }
    when :seasonal_naive then values.each_cons(season_length + 1).map { |window| window.last - window.first }
    when :ses then one_step_errors(values, alpha)
    end
  end

  def error_covariance(model, horizon, season_length: nil, alpha: nil)
    case model
    when :naive then symmetric_matrix(horizon) { |earlier, _later| earlier }
    when :seasonal_naive
      symmetric_matrix(horizon) do |earlier, later|
        (later - earlier) % season_length == 0 ? 1 + (earlier - 1) / season_length : 0
      end
    when :ses
      square = alpha * alpha
      symmetric_matrix(horizon) { |earlier, later| (earlier - 1) * square + (earlier == later ? 1 : alpha) }
    end
  end

  def symmetric_matrix(horizon)
    periods = 1..horizon
    periods.map { |period| periods.map { |other| yield(*[period, other].minmax) } }
  end

  def compound_cdf(probability, sizes, value)
    return 1r if sizes.empty?

    chance = probability.to_r
    1 - chance + chance * Rational(sizes.count { |size| size <= value }, sizes.size)
  end

  def compound_quantiles(probability, observations, levels)
    sizes = observations.reject { |observation| observation == 0 }
    cdf = [0.0, *sizes].uniq.to_h { |value| [value, compound_cdf(probability, sizes, value)] }
    levels.to_h { |level| [level, cdf.select { |_, chance| chance >= level.to_r }.keys.min] }
  end

  def compound_masses(probability, sizes)
    return { 0r => 1r } if sizes.empty?

    chance = probability.to_r
    masses = Hash.new(0r)
    masses[0r] += 1 - chance
    sizes.each { |size| masses[size.to_r] += chance / sizes.size }
    masses
  end

  def total_distribution(probability, sizes, horizon)
    masses = compound_masses(probability, sizes)
    (1..horizon).inject({ 0r => 1r }) do |distribution, _period|
      distribution.each_with_object(Hash.new(0r)) do |(total, mass), convolved|
        masses.each { |size, chance| convolved[total + size] += mass * chance }
      end
    end
  end

  def unreachable_totals(totals, sizes, horizon)
    return totals.reject(&:zero?) if sizes.empty?

    exact = sizes.map(&:to_r)
    denominator = exact.map(&:denominator).inject(:lcm)
    unit = Rational(exact.map { |size| (size * denominator).to_i }.inject(:gcd), denominator)
    steps = exact.map { |size| (size / unit).to_i }.uniq
    mask = (1 << ((totals.max.to_r / unit).floor.clamp(0, horizon * steps.max) + 1)) - 1
    terms = 1
    sums = 0
    horizon.times do
      terms = steps.inject(0) { |union, step| union | (terms << step) } & mask
      sums |= terms
    end
    totals.reject do |total|
      count = total.to_r / unit
      total.zero? || (count.denominator == 1 && sums[count.to_i] == 1)
    end
  end

  def conformal_quantiles(model, values, options, horizon, levels)
    block = options[:windows] * horizon
    before = values.first(values.size - block)
    errors = []
    total_errors = []
    values.last(block).each_slice(horizon) do |window|
      refit = point_forecasts(model, before, options, horizon)
      errors << window.zip(refit).map { |actual, forecast| (actual - forecast).abs }
      total_errors << (window.sum - refit.sum).abs
      before += window
    end
    forecasts = point_forecasts(model, values, options, horizon)
    steps = forecasts.each_with_index.map do |forecast, period|
      empirical_quantiles(plus_minus(forecast, errors.map { |window_errors| window_errors[period] }), levels)
    end
    total = empirical_quantiles(plus_minus(forecasts.sum, total_errors), levels)
    levels.to_h { |level| [level, [steps.map { |quantiles| quantiles[level] }, total[level]]] }
  end

  def plus_minus(center, errors)
    errors.map { |error| center - error } + errors.map { |error| center + error }
  end

  def empirical_quantiles(candidates, levels)
    cdf = candidates.uniq.to_h do |value|
      [value, Rational(candidates.count { |other| other <= value }, candidates.size)]
    end
    levels.to_h { |level| [level, cdf.select { |_, chance| chance >= level.to_r }.keys.min] }
  end
end
