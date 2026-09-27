# frozen_string_literal: true

module Oracles
  ADI_CUTOFF = 1.32r
  CV_SQUARED_CUTOFF = 0.49r
  GOLDEN_RATIO = (1 + Math.sqrt(5)) / 2
  SES_LOWER = 0.01
  SES_UPPER = 0.99
  SES_WIDTH = 1e-12
  OPTION_DEFAULTS = { count: 10, model: nil, levels: [0.5, 0.8, 0.9, 0.95].freeze, strategy: :distribution, seed: 0,
                      season_length: nil, paths: 10_000, windows: 2, alpha: 0.1, alpha_d: 0.1, alpha_p: 0.1 }.freeze
  OPTION_MESSAGES = {
    unknown: "unknown option %s; accepted options are :count, :model, :levels, :strategy, :seed, :season_length, " \
             ":paths, :windows, :alpha, :alpha_d, :alpha_p",
    count: "count must be a positive Integer, got %s",
    model: "model %s is not provided; accepted values are :naive, :seasonal_naive, :ses, :croston_classic, " \
           ":croston_sba, :tsb",
    levels: "levels must be a non-empty Array of numbers strictly between 0 and 1",
    level: "quantile level %s must be strictly between 0 and 1",
    strategy: "strategy must be :distribution or :conformal, got %s",
    seed: "seed must be a non-negative Integer, got %s",
    seasonal_naive: "SeasonalNaive requires a positive Integer season_length, got %s",
    season_length: "season_length must be a positive Integer, got %s",
    paths: "paths must be a positive Integer, got %s",
    windows: "windows must be an Integer of at least 2, got %s",
    alpha: "alpha must be a finite real number strictly between 0 and 1, got %s",
    alpha_d: "alpha_d must be a finite real number strictly between 0 and 1, got %s",
    alpha_p: "alpha_p must be a finite real number strictly between 0 and 1, got %s"
  }.freeze

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

  def option_error(options)
    options.each_key do |name|
      return option_failure(:unknown, Generators.text(name)) unless Generators::OPTION_NAMES.include?(name)
    end
    supplied = options.reject { |_, value| NilClass === value }
    Generators::OPTION_NAMES.each do |name|
      failure = checked_option(name, supplied.fetch(name, OPTION_DEFAULTS[name]), supplied[:model])
      return failure if failure
    end
    nil
  end

  def checked_option(name, value, model)
    case name
    when :levels then checked_levels(value)
    when :season_length then checked_season_length(value, model)
    else option_failure(name, Generators.text(value)) unless accepted_option?(name, value)
    end
  end

  def checked_levels(levels)
    return [:levels, OPTION_MESSAGES[:levels]] unless Array === levels && !levels.empty?

    levels.each { |level| return option_failure(:level, Generators.text(level)) unless inside_unit?(level) }
    nil
  end

  def checked_season_length(value, model)
    if model == :seasonal_naive
      option_failure(:seasonal_naive, NilClass === value ? "none" : Generators.text(value)) unless at_least?(value, 1)
    elsif !(NilClass === value || at_least?(value, 1))
      option_failure(:season_length, Generators.text(value))
    end
  end

  def accepted_option?(name, value)
    case name
    when :count, :paths then at_least?(value, 1)
    when :seed then at_least?(value, 0)
    when :windows then at_least?(value, 2)
    when :model then NilClass === value || Generators::MODEL_NAMES.include?(value)
    when :strategy then Generators::STRATEGY_NAMES.include?(value)
    else inside_unit?(value)
    end
  end

  def at_least?(value, minimum)
    Integer === value && value >= minimum
  end

  def inside_unit?(value)
    [Integer, Float, Rational].any? { |type| type === value } && value > 0 && value < 1
  end

  def option_failure(check, shown)
    [check, format(OPTION_MESSAGES.fetch(check), shown)]
  end

  def option_values(options)
    values = OPTION_DEFAULTS.merge(options.reject { |_, value| NilClass === value })
    values.merge(levels: distinct_levels(values[:levels]))
  end

  def distinct_levels(levels)
    levels.each_with_object([]) { |level, kept| kept << level unless kept.any? { |other| other == level } }.sort
  end

  def options_read(model, strategy)
    read = %i[count model levels strategy]
    read << :season_length if model == :seasonal_naive
    read << :alpha if %i[croston_classic croston_sba].include?(model)
    read.push(:alpha_d, :alpha_p) if model == :tsb
    if strategy == :conformal
      read << :windows
    elsif Generators::INTERMITTENT_NAMES.include?(model)
      read.push(:seed, :paths)
    end
    read
  end

  def backtest_settings(options)
    supplied = options.reject { |_, value| NilClass === value }
    horizon = supplied[:horizon]
    shared = option_values(supplied.reject { |name, _| %i[horizon origins step].include?(name) })
    { horizon: horizon, origins: supplied[:origins], step: supplied.fetch(:step, horizon),
      **shared.reject { |name, _| name == :count } }
  end

  def backtest_minimum(settings)
    model = settings[:model] || :ses
    least = model == :seasonal_naive ? settings[:season_length] : 1
    strategy = if settings[:strategy] == :conformal
                 least + settings[:windows] * settings[:horizon]
               elsif Generators::INTERMITTENT_NAMES.include?(model)
                 least
               else
                 least + 1
               end
    [2, strategy, least].max
  end

  def backtest_length(settings)
    backtest_minimum(settings) + settings[:horizon] + settings[:step] * (settings[:origins] - 1)
  end

  def length_message(settings, size)
    "the backtest needs at least #{backtest_length(settings)} observations for horizon #{settings[:horizon]}, " \
      "#{settings[:origins]} origins and step #{settings[:step]}, got #{size}"
  end

  def origin_positions(size, settings)
    origins = settings[:origins]
    (0...origins).map { |origin| size - settings[:horizon] - settings[:step] * (origins - 1 - origin) }
  end

  def float_value(value)
    value.to_f.to_r
  end

  def mase_scale(history)
    values = history.map { |value| float_value(value) }
    values.each_cons(2).sum(0r) { |earlier, later| (later - earlier).abs } / (values.size - 1)
  end

  def mean_absolute_error(actual, forecast)
    actual.zip(forecast).sum(0r) { |value, predicted| (float_value(value) - float_value(predicted)).abs } / actual.size
  end

  def mean_squared_error(actual, forecast)
    total = actual.zip(forecast).sum(0r) do |value, predicted|
      error = float_value(value) - float_value(predicted)
      error * error
    end
    total / actual.size
  end

  def pinball(level, quantile, actual)
    level = level.to_f.to_r
    quantile = float_value(quantile)
    actual = float_value(actual)
    actual >= quantile ? level * (actual - quantile) : (1 - level) * (quantile - actual)
  end

  def origin_metrics(history, held_out, forecast, quantiles, lead_time_quantiles, levels)
    scale = mase_scale(history)
    mae = mean_absolute_error(held_out, forecast)
    zeros = held_out.map { |value| value.to_f.zero? }
    covered = levels.to_h do |level|
      [level, held_out.each_with_index.count { |value, period| value.to_f <= quantiles[level][period] }]
    end
    total = held_out.inject(0.0) { |sum, value| sum + value.to_f }
    { mase_scale: scale, mae: mae, rmse: Math.sqrt(mean_squared_error(held_out, forecast)).to_r,
      mase: scaled_loss(mae, scale), **pinball_parts(held_out, quantiles, levels, zeros, scale),
      zero_held_out: zeros.count(true), nonzero_held_out: zeros.count(false), covered: covered,
      coverage: covered.transform_values { |count| Rational(count, held_out.size).to_f },
      lead_time_hit: levels.to_h { |level| [level, total <= lead_time_quantiles[level]] } }
  end

  def pinball_parts(held_out, quantiles, levels, zeros, scale)
    parts = { scaled_pinball: [true, false], scaled_pinball_zero: [true], scaled_pinball_nonzero: [false] }
    parts.transform_values do |kept|
      levels.to_h do |level|
        losses = held_out.each_with_index.map do |value, period|
          kept.include?(zeros[period]) ? pinball(level, quantiles[level][period], value) : 0r
        end
        [level, scaled_loss(losses.sum(0r) / held_out.size, scale)]
      end
    end
  end

  def scaled_loss(value, scale)
    value / scale unless scale.zero?
  end

  def present_mean(values)
    present = values.compact
    present.sum(0r, &:to_r) / present.size unless present.empty?
  end
end
