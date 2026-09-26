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

  def one_step_sse(values, alpha)
    level = values.first
    values.each_cons(2).inject(0.0) do |sum, (previous, value)|
      level = alpha * previous + (1 - alpha) * level
      sum + (value - level) * (value - level)
    end
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
end
