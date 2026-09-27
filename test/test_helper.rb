# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "date"

SES_TOLERANCE = 1e-5
DETERMINISTIC_TOLERANCE = 1e-9

module WarningGuard
  DIRECTORIES = %w[lib test].map { |name| "#{File.dirname(__dir__)}/#{name}/" }.freeze

  def warn(message, **)
    path = message[/\A(.+?):\d+: warning:/, 1]
    realpath = begin
      File.realpath(path) if path
    rescue SystemCallError
      nil
    end
    raise message if realpath && DIRECTORIES.any? { |directory| realpath.start_with?(directory) }

    super
  end
end

Warning.singleton_class.prepend(WarningGuard)

def run_ruby(*args, env: {}, **options)
  cleared = ENV.keys.grep(/\A(?:RUBYOPT|RUBYLIB|BUNDLER?_.*)\z/).to_h { |name| [name, nil] }
  Open3.capture3(cleared.merge(env), RbConfig.ruby, *args, **options)
end

def safe_inspect(object)
  case object
  when Hash then "{#{object.map { |key, value| "#{safe_inspect(key)} => #{safe_inspect(value)}" }.join(", ")}}"
  when Array then "[#{object.map { |value| safe_inspect(value) }.join(", ")}]"
  else Generators.text(object)
  end
end

class CustomTime < Time
end

class OpaqueObject < BasicObject
  def hash
    __id__
  end

  def eql?(other)
    equal?(other)
  end
end

module Generators
  PATTERNS = %i[zero leading trailing constant smooth erratic intermittent lumpy].freeze
  NUMBER_TYPES = %i[integer float rational mixed].freeze
  UNITS = %i[day week month year second].freeze
  CHANGES = %i[deletion insertion shift].freeze
  ZONES = [:utc, "+00:00", "+09:00", "-03:30", "+05:45", "-12:00", "+14:00"].freeze
  TIME_CLASSES = [Time, CustomTime].freeze
  STEPS = [1, 60, 900, 3600, 86_400, 604_800, Rational(1, 2), Rational(1, 3), Rational(7, 4)].freeze
  NOT_SERIES = [
    [nil, "NilClass"], [42, "Integer"], [2.5, "Float"], ["1, 2, 3", "String"], [:series, "Symbol"], [1..3, "Range"],
    [Date.new(2026, 1, 1), "Date"], [Time.at(0).utc, "Time"], [Complex(1, 2), "Complex"], [true, "TrueClass"],
    [Object.new, "Object"], [OpaqueObject.new, "OpaqueObject"], [BasicObject.new, "BasicObject"]
  ].freeze
  BAD_KEYS = ["2026-01-01", 20_260_101, :today, nil, 1.5, DateTime.new(2026, 1, 1, 12), [2026, 1, 1],
              OpaqueObject.new].freeze
  BAD_VALUES = [nil, "3", Float::NAN, Float::INFINITY, -Float::INFINITY, Complex(1, 0), Complex(2, -3), :five, true,
                [1], OpaqueObject.new].freeze
  NEGATIVE_VALUES = [-1, -250, -0.5, -Float::MIN, -(10**20), Rational(-1, 3), -Float::EPSILON].freeze
  TOO_LARGE_VALUES = [1e15.next_float, 2e15, Float::MAX, 10**15 + 1, 10**400, Rational(3 * 10**15 + 1, 3),
                      Rational(10**400, 7)].freeze
  INJECTED_VALUES = { value: BAD_VALUES, negative: NEGATIVE_VALUES, too_large: TOO_LARGE_VALUES }.freeze
  FREQUENCY_ADVICE = "every period must be present, with a value of zero for periods without demand"
  MODEL_NAMES = %i[naive seasonal_naive ses croston_classic croston_sba tsb].freeze
  STRATEGY_NAMES = %i[distribution conformal].freeze
  OPTION_NAMES = %i[count model levels strategy seed season_length paths windows alpha alpha_d alpha_p].freeze
  INTERMITTENT_NAMES = %i[croston_classic croston_sba tsb].freeze
  BACKTEST_NAMES = %i[horizon origins step model levels strategy seed season_length paths windows alpha alpha_d
                      alpha_p].freeze
  ZEROS = [0, 0.0, -0.0, Rational(0)].freeze
  UNKNOWN_OPTIONS = [:horizon, :origins, :step, :method, :counts, :level, :Count, "count", "model", 7, nil,
                     OpaqueObject.new].freeze
  BAD_SMOOTHING = [false, 0, 1, 0.0, 1.0, -0.1, 1.5, Float::NAN, Float::INFINITY, -Float::INFINITY, Complex(0.5, 0),
                   Rational(3, 2), "0.5", OpaqueObject.new].freeze
  BAD_OPTION_VALUES = {
    count: [false, true, 0, -1, 5.0, Rational(5), Complex(5, 0), "5", OpaqueObject.new],
    model: [false, :arima, :Naive, "ses", 1, OpaqueObject.new],
    levels: [false, 0.5, "0.5", {}, [], 0.5..0.9, OpaqueObject.new],
    strategy: [false, :gaussian, :compound, "conformal", 1],
    seed: [false, -1, 1.0, Rational(1), "0", OpaqueObject.new],
    season_length: [false, 0, -2, 7.0, Rational(12), "12"],
    paths: [false, 0, -5, 2.5, "100"],
    windows: [false, 1, 0, -3, 3.0, "2"],
    alpha: BAD_SMOOTHING, alpha_d: BAD_SMOOTHING, alpha_p: BAD_SMOOTHING
  }.freeze
  BAD_LEVELS = [0, 1, -1, 0.0, 1.0, -0.0, 1.5, Float::NAN, Float::INFINITY, -Float::INFINITY, Complex(0.5, 0),
                Rational(3, 2), Rational(0), "0.5", :half, nil, false, [0.5], OpaqueObject.new].freeze
  VIOLATIONS = %i[value value value value value value unknown level season season].freeze

  Keyed = Struct.new(:input, :keys, :numbers, :period)
  Call = Struct.new(:input, :numbers, :keys, :options)

  module_function

  def run_length(random)
    choice = random.rand(10)
    return choice if choice < 3
    return random.rand(200..400) if choice == 3

    random.rand(3..40)
  end

  def numbers(random, size = run_length(random))
    type = NUMBER_TYPES.sample(random: random)
    magnitudes(random, PATTERNS.sample(random: random), size).map { |magnitude| number(random, magnitude, type) }
  end

  def magnitudes(random, pattern, size)
    case pattern
    when :zero then Array.new(size, 0)
    when :constant then Array.new(size, random.rand(1..50))
    when :leading, :trailing
      zeros = Array.new(random.rand(0..size), 0)
      demand = Array.new(size - zeros.size) { random.rand(1..30) }
      pattern == :leading ? zeros + demand : demand + zeros
    when :smooth
      level = random.rand(5.0..50.0)
      cycle = random.rand(4..24)
      Array.new(size) { |index| level * (1 + 0.3 * Math.sin(2 * Math::PI * index / cycle)) }
    when :erratic then Array.new(size) { random.rand < 0.05 ? 10.0**random.rand(5..15) : random.rand(0.0..100.0) }
    when :intermittent then Array.new(size) { random.rand < 0.2 ? random.rand(1..3) : 0 }
    else Array.new(size) { random.rand < 0.2 ? random.rand(1..500) : 0 }
    end
  end

  def number(random, magnitude, type)
    type = NUMBER_TYPES.first(3).sample(random: random) if type == :mixed
    case type
    when :integer then magnitude.round
    when :rational then Rational((magnitude * 12).round, 12)
    else magnitude.zero? && random.rand < 0.2 ? -0.0 : magnitude.to_f
    end
  end

  def keyed(random, unit: UNITS.sample(random: random), size: run_length(random))
    keys, period = regular_keys(random, unit, size)
    amounts = numbers(random, keys.size)
    Keyed.new(keys.zip(amounts).shuffle(random: random).to_h, keys, amounts, period)
  end

  def regular_keys(random, unit, size)
    case unit
    when :day, :week
      start = random.rand(2_400_000..2_500_000)
      stride = unit == :day ? 1 : 7
      [Array.new(size) { |index| Date.jd(start + stride * index) }, unit]
    when :month then [monthly_keys(random, size), unit]
    when :year then [yearly_keys(random, size), unit]
    else time_keys(random, size)
    end
  end

  def monthly_keys(random, size)
    loop do
      day = random.rand < 0.4 ? random.rand(29..31) : random.rand(1..28)
      start = random.rand(22_800..24_400)
      keys = Array.new(size) { |index| calendar_date(start + index, day) }.take_while(&:itself)
      return keys if keys.size >= [size, 2].min
    end
  end

  def yearly_keys(random, size)
    month = random.rand(1..12)
    day = random.rand(1..Date.new(2001, month, -1).day)
    start = random.rand(1700..2100)
    Array.new(size) { |index| Date.new(start + index, month, day) }
  end

  def time_keys(random, size)
    step = random.rand < 0.5 ? STEPS.sample(random: random) : Rational(random.rand(1..1_000_000), random.rand(1..12))
    start = random.rand(-1_000_000_000..3_000_000_000) + Rational(random.rand(0..11), 12)
    mixed = random.rand < 0.3
    type = TIME_CLASSES.sample(random: random)
    zone = ZONES.sample(random: random)
    keys = Array.new(size) do |index|
      time_at(start + step * index, mixed ? TIME_CLASSES.sample(random: random) : type,
              mixed ? ZONES.sample(random: random) : zone)
    end
    [keys, Rational(step)]
  end

  def time_at(seconds, type, zone)
    time = type.at(seconds)
    zone == :utc ? time.utc : time.getlocal(zone)
  end

  def change(random, pairs, period)
    pairs = pairs.dup
    index = random.rand(pairs.size)
    kind = CHANGES.sample(random: random)
    case kind
    when :deletion then pairs.delete_at(index)
    when :insertion then pairs.insert(random.rand(0..pairs.size), [nearby(random, pairs[index].first, period), 1])
    else pairs[index] = [nearby(random, pairs[index].first, period), pairs[index].last]
    end
    [kind, pairs]
  end

  def nearby(random, key, period)
    sign = [-1, 1].sample(random: random)
    return Date.jd(key.jd + sign * random.rand(1..40)) if Date === key

    offset = sign * period * Rational(random.rand(1..30), random.rand(1..4))
    time_at(key.to_r + offset, key.class, key.utc? ? :utc : key.utc_offset)
  end

  def invalid_series(random)
    loop do
      if random.rand < 0.1
        object, name = NOT_SERIES.sample(random: random)
        return [object, random.rand < 0.5, :container,
                "series must be a Hash with Date or Time keys or an Array of numbers, got #{name}"]
      end
      input, keys_required = injected(random)
      found = violation(input, keys_required)
      return [input, keys_required, *found] if found
    end
  end

  def injected(random)
    return [injected_numbers(random), random.rand < 0.5] if random.rand < 0.25

    sample = keyed(random)
    kinds = %i[key value negative too_large count frequency].sample(random.rand(1..3), random: random)
    pairs = sample.keys.zip(sample.numbers)
    pairs = pairs.first(random.rand(0..1)) if kinds.include?(:count)
    pairs = change(random, pairs, sample.period).last if kinds.include?(:frequency) && !pairs.empty?
    pairs.shuffle!(random: random)
    INJECTED_VALUES.each { |kind, pool| replace_value(random, pairs, pool) if kinds.include?(kind) }
    pairs.insert(random.rand(0..pairs.size), [bad_key(random, sample.keys), 1]) if kinds.include?(:key)
    [pairs.to_h, kinds.include?(:count) || random.rand < 0.5]
  end

  def injected_numbers(random)
    amounts = numbers(random)
    INJECTED_VALUES.keys.sample(random.rand(1..3), random: random).each do |kind|
      amounts.insert(random.rand(0..amounts.size), INJECTED_VALUES.fetch(kind).sample(random: random))
    end
    amounts
  end

  def replace_value(random, pairs, pool)
    return if pairs.empty?

    index = random.rand(pairs.size)
    pairs[index] = [pairs[index].first, pool.sample(random: random)]
  end

  def bad_key(random, keys)
    return BAD_KEYS.sample(random: random) if random.rand < 0.6

    Date === keys.first ? time_at(random.rand(1_000_000_000), Time, :utc) : Date.jd(random.rand(2_400_000..2_500_000))
  end

  def text(object)
    Object === object ? object.inspect : "#<#{Kernel.instance_method(:class).bind_call(object)}>"
  end

  def key_kind(key)
    if Date === key
      :date unless DateTime === key
    elsif Time === key
      :time
    end
  end

  def key_text(key)
    key_kind(key) == :date ? key.to_s : text(key)
  end

  def calendar_date(month_index, day)
    year, month = month_index.divmod(12)
    Date.new(year, month + 1, day) if Date.valid_date?(year, month + 1, day)
  end

  def next_date(date, unit, periods = 1)
    case unit
    when :day then Date.jd(date.jd + periods)
    when :week then Date.jd(date.jd + 7 * periods)
    when :month then calendar_date(date.year * 12 + date.month - 1 + periods, date.day)
    else calendar_date((date.year + periods) * 12 + date.month - 1, date.day)
    end
  end

  def future_keys(last, period, count)
    (1..count).map { |periods| Symbol === period ? next_date(last, period, periods) : last.to_r + period * periods }
  end

  def overflow(last, count)
    months = (1..count).map { |periods| last.year * 12 + last.month - 1 + periods }
    missing = months.find { |month| calendar_date(month, last.day).nil? }
    return unless missing

    year, month = missing.divmod(12)
    format("cannot key monthly forecasts after %s: %04d-%02d has no day %d", last, year, month + 1, last.day)
  end

  def violation(input, keys_required)
    return value_violation(input, nil) if Array === input

    keys = input.keys
    kind = key_kind(keys.first)
    index = keys.index { |key| kind.nil? || key_kind(key) != kind }
    return [:key, "series keys must be all Date values or all Time values, got #{key_text(keys[index])}"] if index

    keys = keys.sort
    value_violation(keys.map { |key| input[key] }, keys) || count_violation(keys, keys_required) ||
      frequency_violation(keys)
  end

  def value_violation(values, keys)
    index = values.index { |value| !finite_real?(value) }
    return [:value, "series value #{observed(values, keys, index)} is not a finite real number"] if index

    index = values.index { |value| value < 0 }
    return [:negative, "series value #{observed(values, keys, index)} is negative"] if index

    index = values.index { |value| value > 10**15 }
    [:too_large, "series value #{observed(values, keys, index)} is greater than 1e15"] if index
  end

  def finite_real?(value)
    [Integer, Rational, Float].any? { |type| type === value } && value.finite?
  end

  def observed(values, keys, index)
    place = keys ? "key #{key_text(keys[index])}" : "position #{index}"
    "#{text(values[index])} at #{place}"
  end

  def count_violation(keys, keys_required)
    return unless keys_required && keys.size < 2

    [:count, "a keyed series needs at least two keys to determine its frequency, got #{keys.size}"]
  end

  def frequency_violation(keys)
    return if keys.size < 2

    period = implied_period(keys[0], keys[1])
    pair = keys.each_cons(2).find { |earlier, later| period.nil? || !regular?(earlier, later, period) }
    return unless pair

    [:frequency, "keys #{key_text(pair[0])} and #{key_text(pair[1])} do not follow the series frequency; " \
                 "#{FREQUENCY_ADVICE}"]
  end

  def implied_period(earlier, later)
    if Date === earlier
      %i[day week month year].find { |unit| next_date(earlier, unit) == later }
    elsif later.to_r > earlier.to_r
      later.to_r - earlier.to_r
    end
  end

  def regular?(earlier, later, period)
    Symbol === period ? next_date(earlier, period) == later : later.to_r - earlier.to_r == period
  end

  def option_value(random, name)
    case name
    when :count then random.rand < 0.2 ? 1 : random.rand(1..12)
    when :model then MODEL_NAMES.sample(random: random)
    when :levels then option_levels(random)
    when :strategy then STRATEGY_NAMES.sample(random: random)
    when :seed then random.rand < 0.2 ? 0 : random.rand(2**64)
    when :season_length then random.rand(1..12)
    when :paths then random.rand(1..300)
    when :windows then random.rand(2..4)
    else smoothing_value(random)
    end
  end

  def smoothing_value(random)
    case random.rand(10)
    when 0 then 0.1
    when 1 then [1e-9, 1 - 1e-9].sample(random: random)
    when 2, 3 then Rational(random.rand(1..999), 1000)
    else random.rand(0.001..0.999)
    end
  end

  def option_levels(random)
    levels = Array.new(random.rand(1..6)) do
      case random.rand(6)
      when 0 then [1e-6, 1 - 1e-6].sample(random: random)
      when 1, 2 then [0.5, 0.8, 0.9, 0.95].sample(random: random)
      else Rational(random.rand(1..999), 1000)
      end
    end
    levels.insert(random.rand(0..levels.size), levels.sample(random: random).to_r) if random.rand < 0.2
    levels.insert(random.rand(0..levels.size), *[0.5, Rational(1, 2)].shuffle(random: random)) if random.rand < 0.1
    levels
  end

  def forecast_options(random, model, strategy)
    fixed = { model: model, strategy: strategy, paths: 200 }
    fixed[:season_length] = random.rand(1..12) if model == :seasonal_naive
    options = {}
    OPTION_NAMES.each do |name|
      value = fixed.fetch(name) { option_value(random, name) }
      optional = !fixed.key?(name) || [nil, :distribution].include?(value)
      case optional ? random.rand(3) : 0
      when 0 then options[name] = value
      when 1 then options[name] = nil
      end
    end
    options.to_a.shuffle(random: random).to_h
  end

  def shortest_history(options)
    model = options[:model]
    if options[:strategy] == :conformal
      (model == :seasonal_naive ? options[:season_length] : 1) + (options[:windows] || 2) * (options[:count] || 10)
    elsif model == :seasonal_naive
      options[:season_length] + 1
    else
      INTERMITTENT_NAMES.include?(model) ? 1 : 2
    end
  end

  def forecast_keys(random, size)
    unit = UNITS.sample(random: random)
    return regular_keys(random, unit, size).first unless unit == :month

    start = random.rand(22_800..24_400)
    day = random.rand(1..28)
    Array.new(size) { |index| calendar_date(start + index, day) }
  end

  def forecast_call(random, model:, strategy:, keyed:)
    options = forecast_options(random, model, strategy)
    shortest = shortest_history(options)
    size = (keyed ? [shortest, 2].max : shortest) + extra_length(random)
    amounts = numbers(random, size).map { |value| [value, 1e6].min }
    amounts[random.rand(size)] = random.rand(1..50) if model.nil? && amounts.all?(&:zero?)
    return Call.new(amounts, amounts, nil, options) unless keyed

    keys = forecast_keys(random, size)
    Call.new(keys.zip(amounts).shuffle(random: random).to_h, amounts, keys, options)
  end

  def extra_length(random)
    choice = random.rand(10)
    return 0 if choice < 3
    return random.rand(100..200) if choice == 3

    random.rand(1..40)
  end

  def invalid_options(random)
    options = forecast_options(random, [nil, *MODEL_NAMES].sample(random: random),
                               STRATEGY_NAMES.sample(random: random))
    (random.rand < 0.6 ? 1 : random.rand(2..3)).times { inject_violation(random, options) }
    options.to_a.shuffle(random: random).to_h
  end

  def inject_violation(random, options)
    case VIOLATIONS.sample(random: random)
    when :unknown then options[UNKNOWN_OPTIONS.sample(random: random)] = random.rand < 0.4 ? nil : random.rand(1..9)
    when :value
      name = OPTION_NAMES.sample(random: random)
      options[name] = BAD_OPTION_VALUES.fetch(name).sample(random: random)
    when :level
      levels = option_levels(random)
      options[:levels] = levels.insert(random.rand(0..levels.size), BAD_LEVELS.sample(random: random))
    else
      options[:model] = :seasonal_naive
      options[:season_length] = [nil, BAD_OPTION_VALUES[:season_length].sample(random: random)].sample(random: random)
      options.delete(:season_length) if random.rand < 0.3
    end
  end

  def backtest_options(random, model, strategy)
    fixed = { horizon: random.rand(1..7), origins: random.rand(1..5), model: model, strategy: strategy, paths: 200 }
    fixed[:season_length] = random.rand(1..12) if model == :seasonal_naive
    chosen = { step: random.rand(1..7), windows: random.rand(2..3) }
    options = {}
    BACKTEST_NAMES.each do |name|
      value = fixed.fetch(name) { chosen.fetch(name) { option_value(random, name) } }
      optional = !fixed.key?(name) || [nil, :distribution].include?(value)
      case optional ? random.rand(3) : 0
      when 0 then options[name] = value
      when 1 then options[name] = nil
      end
    end
    options.to_a.shuffle(random: random).to_h
  end

  def backtest_values(random, size, horizon, mixed: false)
    zero = ZEROS.sample(random: random)
    pick_zero = -> { mixed ? ZEROS.sample(random: random) : zero }
    values = numbers(random, size).map { |value| value.zero? || random.rand < 0.1 ? pick_zero.call : [value, 1e6].min }
    run = random.rand(1..[size - horizon, 1].max)
    case random.rand(4)
    when 0 then values.fill(0, run) { pick_zero.call }
    when 1
      level = random.rand(1..50)
      values.fill(0, run) { mixed ? [level, level.to_f, Rational(level)].sample(random: random) : level }
    end
    values
  end

  def backtest_call(random, options, values, keyed:)
    return Call.new(values, values, nil, options) unless keyed

    keys = forecast_keys(random, values.size)
    Call.new(keys.zip(values).shuffle(random: random).to_h, values, keys, options)
  end

  def metric_float(random)
    case random.rand(6)
    when 0 then [0.0, -0.0, 0.5, 1.0].sample(random: random)
    when 1 then random.rand(1..1000).to_f
    when 2 then random.rand
    when 3 then random.rand(-1000.0..1000.0)
    else random.rand(0.0..1e6) / 10**random.rand(0..9)
    end
  end
end
