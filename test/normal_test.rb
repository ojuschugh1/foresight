# frozen_string_literal: true

require "test_helper"
require "oracles"
require "foresight"

class NormalTest < Minitest::Test
  SEED = 15_485_863
  TOLERANCE = 1e-9
  LOWEST = 1e-6
  HIGHEST = 1 - 1e-6
  ENDPOINTS = [LOWEST, HIGHEST, Rational(1, 10**6), 1 - Rational(1, 10**6)].freeze
  TINY = Rational(1, 10**400)
  BOUNDARIES = [Math.exp(-25), 0.075, 0.925, 1 - Math.exp(-25)].freeze
  BOUNDARY_STEP = 1e-12
  TABLE_TOLERANCE = 6e-13
  COVERAGE_TABLE = {
    0.8r => 1.281551565545, 0.9r => 1.644853626951, 0.95r => 1.959963984540, 0.98r => 2.326347874041,
    0.99r => 2.575829303549, 0.995r => 2.807033768344, 0.998r => 3.090232306168, 0.999r => 3.290526731492,
    0.9999r => 3.890591886413, 0.99999r => 4.417173413469, 0.999999r => 4.891638475699,
    0.9999999r => 5.326723886384, 0.99999999r => 5.730728868236, 0.999999999r => 6.109410204869
  }.freeze

  def test_quantile_stays_within_1e_9_of_a_bisection_on_erfc
    kinds = []
    each_seed(1_000) do |seed, random|
      kind, level = accurate_level(random)
      about = "seed #{seed}, level #{level.inspect}"
      value = Foresight::Normal.quantile(level)

      assert_instance_of Float, value, about
      assert_in_delta Oracles.normal_quantile(level), value, TOLERANCE, about
      kinds << kind
    end
    assert_equal %i[endpoint far_lower far_upper lower rational uniform upper], kinds.uniq.sort, "seed #{SEED}"
  end

  def test_float_and_rational_levels_between_zero_and_one_give_finite_values
    seen = []
    each_seed(500) do |seed, random|
      kind, level = open_level(random)
      about = "seed #{seed}, level #{level.inspect}"
      value = Foresight::Normal.quantile(level)

      assert_instance_of Float, value, about
      assert_predicate value, :finite?, about
      assert_equal level.to_f <=> 0.5, value <=> 0, about
      seen << kind
      seen << :zero_float if level.to_f == 0.0
      seen << :one_float if level.to_f == 1.0
    end
    assert_equal %i[float one_float rational zero_float], seen.uniq.sort, "seed #{SEED}"
  end

  def test_levels_at_the_ends_of_the_float_range_give_finite_values
    lowest = Foresight::Normal.quantile(Float::MIN)
    highest = Foresight::Normal.quantile(1.0 - Float::EPSILON / 2)

    assert_equal [0.0, 1.0], [TINY.to_f, (1 - TINY).to_f]
    [TINY, 0.0.next_float, Float::MIN.prev_float].each do |level|
      assert_equal lowest, Foresight::Normal.quantile(level), level.inspect
    end
    assert_equal highest, Foresight::Normal.quantile(1 - TINY)
    assert_equal [-1, 1], [lowest <=> 0, highest <=> 0]
    assert_predicate lowest, :finite?
    assert_predicate highest, :finite?
    assert_equal Foresight::Normal.quantile(0.8), Foresight::Normal.quantile(Rational(4, 5))
  end

  def test_quantile_does_not_decrease_across_the_boundaries_between_approximations
    BOUNDARIES.each do |boundary|
      tail = [boundary, 1 - boundary].min
      step = [tail * BOUNDARY_STEP, boundary.next_float - boundary].max
      levels = (-1_000..1_000).map { |index| boundary + index * step }

      assert_non_decreasing levels, "around #{boundary.inspect} in steps of #{step.inspect}"
    end
  end

  def test_quantile_does_not_decrease_over_random_sorted_levels
    each_seed(200) do |seed, random|
      levels = Array.new(100) { open_level(random).last }.sort

      assert_non_decreasing levels, "seed #{seed}: #{levels.inspect}"
    end
  end

  def test_quantile_matches_a_published_twelve_decimal_table
    assert_equal 0.0, Foresight::Normal.quantile(0.5)
    COVERAGE_TABLE.each do |coverage, deviate|
      level = (1 - coverage) / 2

      assert_in_delta(-deviate, Foresight::Normal.quantile(level), TABLE_TOLERANCE, "coverage #{coverage.to_f}")
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

  def accurate_level(random)
    case random.rand(12)
    when 0 then [:endpoint, ENDPOINTS.sample(random: random)]
    when 1, 2 then [:lower, 10.0**random.rand(-6.0..-1.0)]
    when 3, 4 then [:upper, 1 - 10.0**random.rand(-6.0..-1.0)]
    when 5, 6 then [:rational, Rational(random.rand(1..999_999), 1_000_000)]
    when 7 then [:far_lower, 10.0**random.rand(-307.0..-6.0)]
    when 8 then [:far_upper, 1 - 10.0**random.rand(-15.0..-6.0)]
    else [:uniform, random.rand(LOWEST..HIGHEST)]
    end
  end

  def open_level(random)
    case random.rand(6)
    when 0 then [:float, Math.ldexp(1 + random.rand, random.rand(-1074..-2))]
    when 1 then [:float, 1 - Math.ldexp(1 + random.rand, random.rand(-53..-2))]
    when 2 then [:rational, Rational(random.rand(1..9), 10**random.rand(1..500))]
    when 3 then [:rational, 1 - Rational(random.rand(1..9), 10**random.rand(1..500))]
    when 4 then [:rational, Rational(random.rand(1..10**6), 10**6 + 1)]
    else [:float, random.rand(LOWEST..HIGHEST)]
    end
  end

  def assert_non_decreasing(levels, about)
    values = levels.map { |level| Foresight::Normal.quantile(level) }
    drops = levels.zip(values).each_cons(2).reject { |(_, value), (_, following)| following >= value }

    assert_empty drops, about
  end
end
