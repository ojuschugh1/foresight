# frozen_string_literal: true

require "test_helper"
require "oracles"
require "foresight"

class ClassifierTest < Minitest::Test
  SEED = 1_299_709
  TOLERANCE = Rational("1e-9")

  def test_classify_matches_the_exact_oracle_on_random_series
    classes = []
    each_seed(200) do |seed, random|
      input = demanded { random.rand < 0.3 ? Generators.numbers(random) : Generators.keyed(random).input }
      about = details(seed, input)
      exact = Oracles.classification(observations(input))

      assert_classification exact, classified(input, about), about
      classes << exact[:demand_class]
    end
    assert_equal %i[erratic intermittent lumpy smooth], classes.uniq.sort, "seed #{SEED}"
  end

  def test_classify_matches_the_exact_oracle_on_series_tied_at_the_cutoffs
    seen = []
    each_seed(200) do |seed, random|
      input = tied(random)
      about = details(seed, input)
      exact = Oracles.classification(input)
      result = classified(input, about)

      assert_classification exact, result, about
      seen << :adi if exact[:adi] == Oracles::ADI_CUTOFF
      seen << :cv_squared if exact[:cv_squared] == Oracles::CV_SQUARED_CUTOFF
      seen << :rounded_up if exact[:cv_squared] < Oracles::CV_SQUARED_CUTOFF && result.cv_squared >= 0.49
    end
    assert_equal %i[adi cv_squared rounded_up], seen.uniq.sort, "seed #{SEED}"
  end

  def test_scaling_keeps_the_adi_the_cv_squared_and_the_demand_class_away_from_the_cutoff
    compared = []
    near_cutoff = 0
    each_seed(200) do |seed, random|
      input = scalable(random)
      factor = scale_factor(random)
      about = "seed #{seed}, c #{factor.inspect}: #{safe_inspect(input)}"
      original = classified(input, about)
      scaled = classified(map_values(input) { |value| value * factor }, about)
      difference = (scaled.cv_squared.to_r - original.cv_squared.to_r).abs

      assert_equal original.adi, scaled.adi, about
      assert_operator difference, :<=, bound(original.cv_squared.to_r), about
      if (Oracles.classification(observations(input))[:cv_squared] - Oracles::CV_SQUARED_CUTOFF).abs > TOLERANCE
        assert_equal original.demand_class, scaled.demand_class, about
        compared << original.demand_class
      else
        near_cutoff += 1
      end
    end
    assert_equal %i[erratic intermittent lumpy smooth], compared.uniq.sort, "seed #{SEED}"
    assert_operator near_cutoff, :>, 0, "seed #{SEED}"
  end

  def test_series_without_a_non_zero_observation_are_refused
    [[], {}, [0], [0, 0.0, -0.0, Rational(0)], { Date.new(2026, 3, 1) => 0 },
     { Time.utc(2026, 3, 1) => -0.0, Time.utc(2026, 3, 2) => Rational(0) }].each do |input|
      error = assert_raises(Foresight::InputError, safe_inspect(input)) { Foresight.classify(input) }
      assert_equal "classification requires at least one non-zero observation", error.message, safe_inspect(input)
    end
  end

  def test_a_one_key_hash_is_classified
    [{ Date.new(2026, 3, 1) => 4 }, { Time.utc(2026, 3, 1) => Rational(1, 2) }].each do |input|
      result = Foresight.classify(input)
      assert_equal [:smooth, 1.0, 0.0], [result.demand_class, result.adi, result.cv_squared], safe_inspect(input)
    end
  end

  def test_series_errors_come_before_the_zero_check
    day = Date.new(2026, 1, 1)
    midnight = Time.utc(2026, 1, 1)
    keys = "series keys must be all Date values or all Time values, got"
    advice = Generators::FREQUENCY_ADVICE
    [
      [0, "series must be a Hash with Date or Time keys or an Array of numbers, got Integer"],
      [{ day => 0, midnight => 0 }, "#{keys} 2026-01-01 00:00:00 UTC"],
      [{ day => -1, "2026-01-02" => Float::NAN }, "#{keys} \"2026-01-02\""],
      [[0, -1, Float::NAN], "series value NaN at position 2 is not a finite real number"],
      [[0, 0.0, -0.5], "series value -0.5 at position 2 is negative"],
      [{ day + 2 => -1, day => 0 }, "series value -1 at key 2026-01-03 is negative"],
      [{ day => 0, day + 2 => 0.0 }, "keys 2026-01-01 and 2026-01-03 do not follow the series frequency; #{advice}"],
      [{ midnight => 0, midnight + 3600 => 0, midnight + 10_800 => 0 },
       "keys 2026-01-01 01:00:00 UTC and 2026-01-01 03:00:00 UTC do not follow the series frequency; #{advice}"]
    ].each do |input, message|
      error = assert_raises(Foresight::InputError, safe_inspect(input)) { Foresight.classify(input) }
      assert_equal message, error.message
    end
  end

  private

  def each_seed(count)
    rng = Random.new(SEED)
    count.times do
      seed = rng.rand(2**32)
      yield seed, Random.new(seed)
    end
  end

  def details(seed, input)
    "seed #{seed}: #{safe_inspect(input)}"
  end

  def demanded
    loop do
      input = yield
      return input if observations(input).any? { |value| value != 0 }
    end
  end

  def observations(input)
    Hash === input ? input.values : input
  end

  def map_values(input, &block)
    Hash === input ? input.transform_values(&block) : input.map(&block)
  end

  def tied(random)
    groups = random.rand(1..4)
    sizes, zeros = case random.rand(3)
                   when 0 then [Array.new(25 * groups) { demand_size(random) }, 8 * groups]
                   when 1 then [cv_squared_tie(random, random.rand(1..30)), random.rand(0..40)]
                   else [cv_squared_tie(random, 25 * groups), 16 * groups]
                   end
    (sizes + Array.new(zeros) { Generators.number(random, 0, :mixed) }).shuffle(random: random)
  end

  def demand_size(random)
    Generators.number(random, 10.0**random.rand(0.0..6.0), :mixed)
  end

  def cv_squared_tie(random, pairs)
    scale = case random.rand(3)
            when 0 then random.rand(1..50_000)
            when 1 then Rational(random.rand(1..10_000), random.rand(1..10_000))
            else 10.0**random.rand(-6.0..4.0)
            end
    [17 * scale] * pairs + [3 * scale] * pairs
  end

  def scalable(random)
    return tied(random) if random.rand < 0.25

    demanded do
      input = random.rand < 0.3 ? Generators.numbers(random) : Generators.keyed(random).input
      map_values(input) { |value| value.zero? ? value : value.clamp(1e-6, 1e6) }
    end
  end

  def scale_factor(random)
    case random.rand(10)
    when 0 then 1e-6
    when 1 then 1e6
    else 10.0**random.rand(-6.0..6.0)
    end
  end

  def classified(input, about)
    Foresight.classify(input)
  rescue Foresight::InputError => e
    flunk "#{about}: #{e.message}"
  end

  def assert_classification(exact, result, about)
    assert_equal exact[:demand_class], result.demand_class, about
    [[exact[:adi], result.adi], [exact[:cv_squared], result.cv_squared]].each do |value, returned|
      assert_instance_of Float, returned, about
      difference = (returned.to_r - value).abs
      assert_operator difference, :<=, bound(value), about
    end
  end

  def bound(value)
    TOLERANCE * [value, 1].max
  end
end
