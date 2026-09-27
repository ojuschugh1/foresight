# frozen_string_literal: true

require "test_helper"
require "foresight"

class SeriesTest < Minitest::Test
  SEED = 104_729

  def test_valid_input_parses_to_float_values_in_key_order_and_is_left_unchanged
    each_seed(200) do |seed, random|
      input, numbers, keys = valid_input(random)
      keys_required = (keys.nil? || keys.size >= 2) && random.rand < 0.5
      input.freeze if random.rand < 0.3
      frozen = input.frozen?
      before = Marshal.dump(input)
      about = details(seed, input, keys_required)
      series = accepted(input, keys_required, about)
      expected = [numbers.map { |number| number.to_f.inspect }, numbers.map(&:inspect), keys]

      assert_equal expected, contents(series), about
      assert_equal keys.nil? || keys.size < 2, series.frequency.nil?, about
      assert_equal before, Marshal.dump(input), about
      assert_equal frozen, input.frozen?, about
      next if frozen

      input.clear
      assert_equal expected, contents(series), about
    end
  end

  def test_injected_violations_raise_for_the_first_violated_criterion
    seen = []
    each_seed(200) do |seed, random|
      input, keys_required, kind, message = Generators.invalid_series(random)
      about = details(seed, input, keys_required)
      error = assert_raises(Foresight::InputError, about) { parse(input, keys_required) }
      assert_equal message, error.message, about
      seen << kind
    end
    assert_equal %i[container count frequency key negative too_large value], seen.uniq.sort
  end

  def test_detected_frequency_keys_the_future_and_holds_for_the_extended_series
    overflows = 0
    each_seed(200) do |seed, random|
      sample = Generators.keyed(random, size: [Generators.run_length(random), 2].max)
      keys_required = random.rand < 0.5
      about = details(seed, sample.input, keys_required)
      series = accepted(sample.input, keys_required, about)
      assert_frequency sample.period, series.frequency, about

      count = random.rand(1..30)
      last = sample.keys.last
      overflow = Generators.overflow(last, count) if sample.period == :month
      if overflow
        error = assert_raises(Foresight::InputError, about) { series.future_keys(count) }
        assert_equal overflow, error.message, about
        overflows += 1
        next
      end

      future = series.future_keys(count)
      expected = Generators.future_keys(last, sample.period, count)
      assert_equal expected, future.map { |key| Time === key ? key.to_r : key }, about
      assert_equal [zone_of(last)] * count, future.map { |key| zone_of(key) }, about
      extended = accepted(sample.input.merge(future.to_h { |key| [key, 0] }), true, about)
      assert_frequency sample.period, extended.frequency, about
    end
    assert_operator overflows, :>, 0
  end

  def test_a_single_changed_key_names_the_first_pair_off_the_frequency
    broken = Hash.new(0)
    each_seed(200) do |seed, random|
      sample = Generators.keyed(random, size: random.rand(3..40))
      change, pairs = Generators.change(random, sample.keys.zip(sample.numbers), sample.period)
      input = pairs.shuffle(random: random).to_h
      keys_required = random.rand < 0.5
      about = details(seed, input, keys_required)
      keys = input.keys.sort
      found = Generators.frequency_violation(keys)
      if found
        error = assert_raises(Foresight::InputError, about) { parse(input, keys_required) }
        assert_equal found.last, error.message, about
        broken[change] += 1
      else
        series = accepted(input, keys_required, about)
        assert_frequency Generators.implied_period(keys[0], keys[1]), series.frequency, about
      end
    end
    assert_equal Generators::CHANGES.sort, broken.keys.sort
  end

  def test_an_empty_array_is_an_empty_series
    [true, false].each { |keys_required| assert_empty parse([], keys_required).values }
  end

  def test_hashes_with_fewer_than_two_keys_are_refused_only_when_keys_are_required
    [{}, { Date.new(2026, 3, 1) => 4 }, { Time.utc(2026, 3, 1) => Rational(1, 2) }].each do |input|
      error = assert_raises(Foresight::InputError) { parse(input) }
      assert_equal "a keyed series needs at least two keys to determine its frequency, got #{input.size}",
                   error.message
      series = parse(input, false)
      assert_equal input.values.map(&:to_f), series.values
      assert_nil series.frequency
    end
  end

  def test_date_time_keys_are_neither_date_nor_time_values
    first = DateTime.new(2026, 1, 1)
    [{ first => 1, DateTime.new(2026, 1, 2) => 2 }, { Date.new(2025, 12, 31) => 1, first => 2 }].each do |input|
      error = assert_raises(Foresight::InputError) { parse(input) }
      assert_equal "series keys must be all Date values or all Time values, got #{first.inspect}", error.message
    end
  end

  def test_mixed_keys_name_the_first_key_of_another_kind
    [
      [{ Date.new(2026, 1, 1) => 1, Time.utc(2026, 1, 3) => 2, Date.new(2026, 1, 2) => 3 }, "2026-01-03 00:00:00 UTC"],
      [{ CustomTime.utc(2026, 1, 1) => 1, Time.utc(2026, 1, 2) => 2, Date.new(2026, 1, 3) => 3 }, "2026-01-03"],
      [{ "2026-01-01" => 1, Date.new(2026, 1, 2) => 2 }, "\"2026-01-01\""],
      [{ Date.new(2026, 1, 1) => 1, nil => 2 }, "nil"]
    ].each do |input, key|
      error = assert_raises(Foresight::InputError) { parse(input) }
      assert_equal "series keys must be all Date values or all Time values, got #{key}", error.message
    end
  end

  def test_basic_objects_are_named_by_their_class
    identity = {}.compare_by_identity
    identity[BasicObject.new] = 1
    [
      [OpaqueObject.new, "series must be a Hash with Date or Time keys or an Array of numbers, got OpaqueObject"],
      [BasicObject.new, "series must be a Hash with Date or Time keys or an Array of numbers, got BasicObject"],
      [{ OpaqueObject.new => 1 }, "series keys must be all Date values or all Time values, got #<OpaqueObject>"],
      [identity, "series keys must be all Date values or all Time values, got #<BasicObject>"],
      [{ Date.new(2026, 1, 2) => OpaqueObject.new, Date.new(2026, 1, 1) => 2 },
       "series value #<OpaqueObject> at key 2026-01-02 is not a finite real number"],
      [[1, BasicObject.new], "series value #<BasicObject> at position 1 is not a finite real number"]
    ].each do |input, message|
      error = assert_raises(Foresight::InputError) { parse(input) }
      assert_equal message, error.message
    end
  end

  def test_negative_zero_is_accepted_and_kept
    [[-0.0, 2], { Date.new(2026, 1, 2) => 2, Date.new(2026, 1, 1) => -0.0 }].each do |input|
      assert_equal %w[-0.0 2.0], parse(input).values.map(&:to_s)
    end
  end

  def test_values_that_are_not_finite_real_numbers_are_refused
    [[nil, "nil"], ["3", "\"3\""], [Float::NAN, "NaN"], [Float::INFINITY, "Infinity"], [-Float::INFINITY, "-Infinity"],
     [Complex(1, 0), "(1+0i)"], [Complex(2, -3), "(2-3i)"]].each do |value, shown|
      error = assert_raises(Foresight::InputError) { parse([2, value]) }
      assert_equal "series value #{shown} at position 1 is not a finite real number", error.message
      keyed = { Time.utc(2026, 1, 2) => value, Time.utc(2026, 1, 1) => 2 }
      error = assert_raises(Foresight::InputError) { parse(keyed) }
      assert_equal "series value #{shown} at key 2026-01-02 00:00:00 UTC is not a finite real number", error.message
    end
  end

  def test_values_of_exactly_1e15_are_accepted
    bound = [10**15, 1e15, Rational(10**15)]
    keyed = { Date.new(2026, 1, 3) => bound[2], Date.new(2026, 1, 1) => bound[0], Date.new(2026, 1, 2) => bound[1] }
    [bound, keyed].each do |input|
      series = parse(input)
      forecast = Foresight.forecast(input, model: :naive, count: 2).forecast

      assert_equal [1e15] * 3, series.values
      assert_equal bound.map(&:inspect), series.exact.map(&:inspect)
      assert_equal :smooth, Foresight.classify(input).demand_class
      assert_equal [1e15] * 2, Hash === forecast ? forecast.values : forecast
    end
  end

  def test_values_greater_than_1e15_are_refused_by_forecast_and_classify
    Generators::TOO_LARGE_VALUES.each do |value|
      keyed = { Date.new(2026, 1, 2) => value, Date.new(2026, 1, 1) => 2 }
      [[[2, value], "position 1"], [keyed, "key 2026-01-02"]].each do |input, place|
        message = "series value #{value.inspect} at #{place} is greater than 1e15"
        forecast = assert_raises(Foresight::InputError, message) { Foresight.forecast(input, model: :naive) }
        classify = assert_raises(Foresight::InputError, message) { Foresight.classify(input) }

        assert_equal message, forecast.message
        assert_equal message, classify.message
      end
    end
  end

  def test_negative_and_non_finite_values_are_reported_before_values_greater_than_1e15
    day = Date.new(2026, 1, 1)
    [
      [[3, -1, 2e15], "series value -1 at position 1 is negative"],
      [[3, 2e15, -1], "series value -1 at position 2 is negative"],
      [{ day + 1 => 10**400, day => 3, day + 2 => -0.5 }, "series value -0.5 at key 2026-01-03 is negative"],
      [[10**15 + 1, 3, Float::NAN], "series value NaN at position 2 is not a finite real number"],
      [{ day => Float::MAX, day + 1 => nil }, "series value nil at key 2026-01-02 is not a finite real number"]
    ].each do |input, message|
      error = assert_raises(Foresight::InputError) { parse(input) }
      assert_equal message, error.message
    end
  end

  def test_january_31_is_not_advanced_into_february
    series = parse({ Date.new(2025, 12, 31) => 3, Date.new(2026, 1, 31) => 4 })
    error = assert_raises(Foresight::InputError) { series.future_keys(1) }
    assert_equal "cannot key monthly forecasts after 2026-01-31: 2026-02 has no day 31", error.message
  end

  private

  def each_seed(count)
    rng = Random.new(SEED)
    count.times do
      seed = rng.rand(2**32)
      yield seed, Random.new(seed)
    end
  end

  def valid_input(random)
    if random.rand < 0.3
      input = Generators.numbers(random)
      [input, input.dup, nil]
    else
      sample = Generators.keyed(random)
      [sample.input, sample.numbers, sample.keys]
    end
  end

  def parse(input, keys_required = true)
    Foresight::Series.parse(input, keys_required: keys_required)
  end

  def accepted(input, keys_required, about)
    parse(input, keys_required)
  rescue Foresight::InputError => e
    flunk "#{about}: #{e.message}"
  end

  def details(seed, input, keys_required)
    "seed #{seed}, keys_required #{keys_required}: #{safe_inspect(input)}"
  end

  def contents(series)
    [series.values.map(&:inspect), series.exact.map(&:inspect), series.keys]
  end

  def assert_frequency(period, frequency, about)
    refute_nil frequency, about
    if Symbol === period
      assert_equal period, frequency.unit, about
      assert_nil frequency.seconds, about
    else
      assert_equal :second, frequency.unit, about
      assert_equal period, frequency.seconds, about
    end
  end

  def zone_of(key)
    Time === key ? [key.class, key.utc?, key.utc_offset, key.zone] : [key.class]
  end
end
