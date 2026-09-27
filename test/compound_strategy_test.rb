# frozen_string_literal: true

require "test_helper"
require "oracles"
require "foresight"

class CompoundStrategyTest < Minitest::Test
  SEED = 49_979_687
  NAMES = %i[croston_classic croston_sba tsb].freeze
  OPTIONS = { alpha: 0.1, alpha_d: 0.1, alpha_p: 0.1 }.freeze
  EDGE_LEVELS = [1e-6, 1 - 1e-6].freeze
  EXAMPLE_LEVELS = [1e-6, Rational(1, 20), 0.5, 0.95, 1 - 1e-6].freeze
  MARGIN = 3

  def test_per_period_quantiles_follow_the_compound_distribution
    seen = []
    each_seed(200) do |seed, random|
      values = history(random)
      options = draw_options(random)
      horizon = random.rand(1..60)
      paths = random.rand(1..1_000)
      simulation_seed = random.rand(2**32)
      observed = values.reject(&:zero?)
      about = "seed #{seed}: #{safe_inspect(values)} #{safe_inspect(options)} horizon #{horizon} paths #{paths} " \
              "simulation seed #{simulation_seed}"
      NAMES.each do |name|
        model = Foresight::MODELS.fetch(name).new(values, options)
        probability = model.probability
        levels = sorted_levels(random_levels(random) + boundary_levels(random, probability, observed.size))
        where = "#{about}, #{name}, probability #{probability.inspect}, levels #{safe_inspect(levels)}"
        quantiles = Foresight::CompoundStrategy.new(model, horizon: horizon, levels: levels, paths: paths,
                                                    seed: simulation_seed).quantiles

        assert_instance_of Float, probability, where
        assert probability.between?(0.0, 1.0), where
        assert_equal observed.sort, model.sizes, where
        assert_equal levels, quantiles.keys, where
        Oracles.compound_quantiles(probability, values, levels).each do |level, expected|
          steps = quantiles[level]
          value = steps.first
          at = "#{where}, level #{level.inspect}"

          assert_equal Array.new(horizon, expected), steps, at
          assert steps.all?(Float), at
          if level.to_r <= 1 - probability.to_r
            assert_equal 0.0, value, at
          else
            assert_includes observed, value, at
          end
          seen << :zero if value.zero? && !observed.empty?
          seen << :size if value.positive?
          seen << :largest if value == observed.max && observed.uniq.size > 1
          seen << :boundary if probability.positive? && level.to_r == 1 - probability.to_r
          seen << :jump if value.positive? && Oracles.compound_cdf(probability, observed, value) == level.to_r
          seen << :rational if Rational === level
        end
        seen << :certain if probability == 1.0
      end
      seen << :all_zero if observed.empty?
    end
    assert_equal %i[all_zero boundary certain jump largest rational size zero], seen.uniq.sort, "seed #{SEED}"
  end

  def test_lead_time_quantiles_are_simulated_totals_of_observed_sizes
    seen = []
    each_seed(200) do |seed, random|
      values = summable_history(random)
      options = draw_options(random)
      horizon = random.rand < 0.2 ? 1 : random.rand(1..60)
      paths = random.rand < 0.2 ? random.rand(1..3) : random.rand(1..300)
      simulation_seed = random.rand < 0.1 ? Foresight::DEFAULT_SEED : random.rand(2**64)
      levels = sorted_levels(random_levels(random) + rank_levels(random, paths))
      observed = values.reject(&:zero?)
      about = "seed #{seed}: #{safe_inspect(values)} #{safe_inspect(options)} horizon #{horizon} paths #{paths} " \
              "simulation seed #{simulation_seed} levels #{safe_inspect(levels)}"
      NAMES.each do |name|
        model = Foresight::MODELS.fetch(name).new(values, options)
        totals = Foresight::Simulator.new(probability: model.probability, sizes: model.sizes, horizon: horizon,
                                          paths: paths, seed: simulation_seed).totals
        lead_times = Foresight::CompoundStrategy.new(model, horizon: horizon, levels: levels, paths: paths,
                                                     seed: simulation_seed).lead_time_quantiles
        sorted = totals.sort
        where = "#{about}, #{name}, probability #{model.probability.inspect}"

        assert_equal paths, totals.size, where
        assert totals.all?(Float), where
        assert_empty Oracles.unreachable_totals(totals, observed, horizon), where
        assert_equal levels, lead_times.keys, where
        assert_equal levels.map { |level| sorted[(level.to_r * paths).ceil - 1] }, lead_times.values, where
        seen << :certain if model.probability == 1.0
        seen << :mixed if totals.include?(0.0) && totals.any?(&:positive?)
      end
      seen << :one_path if paths == 1
      seen << :one_period if horizon == 1
      seen << :zero_history if observed.empty?
      seen << :fractional if observed.any? { |size| size.to_r.denominator > 1 }
      seen << :exact_rank if levels.any? { |level| (level.to_r * paths).denominator == 1 }
    end
    assert_equal %i[certain exact_rank fractional mixed one_path one_period zero_history], seen.uniq.sort,
                 "seed #{SEED}"
  end

  def test_lead_time_quantiles_meet_the_bound_against_the_exact_total_distribution
    seen = []
    each_seed(150) do |seed, random|
      values = small_history(random)
      options = draw_options(random)
      horizon = random.rand(1..6)
      paths = random.rand < 0.2 ? [100, 2_000].sample(random: random) : random.rand(100..2_000)
      simulation_seed = random.rand(2**32)
      levels = sorted_levels(random_levels(random))
      observed = values.reject(&:zero?)
      about = "seed #{seed}: #{safe_inspect(values)} #{safe_inspect(options)} horizon #{horizon} paths #{paths} " \
              "simulation seed #{simulation_seed} levels #{safe_inspect(levels)}"
      NAMES.each do |name|
        model = Foresight::MODELS.fetch(name).new(values, options)
        distribution = Oracles.total_distribution(model.probability, observed, horizon)
        lead_times = Foresight::CompoundStrategy.new(model, horizon: horizon, levels: levels, paths: paths,
                                                     seed: simulation_seed).lead_time_quantiles
        lead_times.each do |level, quantile|
          value = quantile.to_r
          at_most = mass(distribution) { |total| total <= value }
          below = mass(distribution) { |total| total < value }
          where = "#{about}, #{name}, probability #{model.probability.inspect}, level #{level.inspect}, " \
                  "quantile #{quantile.inspect}"

          assert inside_margin?(level.to_r - at_most, paths), "#{where}, total at most #{at_most.to_f}"
          assert inside_margin?(below - level.to_r, paths), "#{where}, total below #{below.to_f}"
          seen << :below if at_most < level.to_r
          seen << :above if below > level.to_r
        end
      end
      seen << :one_period if horizon == 1
      seen << :six_periods if horizon == 6
      seen << :fewest_paths if paths == 100
      seen << :most_paths if paths == 2_000
    end
    assert_equal %i[above below fewest_paths most_paths one_period six_periods], seen.uniq.sort, "seed #{SEED}"
  end

  def test_an_occurrence_probability_of_one_puts_a_demand_size_in_every_period
    values = [2.0, 5.0, 3.0, 5.0]
    expected = { 0.2 => [2.0] * 3, 0.25 => [2.0] * 3, 0.5 => [3.0] * 3, 0.8 => [5.0] * 3 }
    [[:croston_classic, values], [:croston_classic, values + [0.0, 0.0]], [:tsb, values]].each do |name, observations|
      model = Foresight::MODELS.fetch(name).new(observations, OPTIONS)
      strategy = Foresight::CompoundStrategy.new(model, horizon: 3, levels: expected.keys, paths: 200, seed: 0)
      about = "#{name} on #{safe_inspect(observations)}"

      assert_equal 1.0, model.probability, about
      assert_equal expected, strategy.quantiles, about
      assert_operator strategy.lead_time_quantiles.values.min, :>=, 6.0, about
    end
    assert_equal 0.95, Foresight::CrostonSBA.new(values, OPTIONS).probability
    totals = Foresight::Simulator.new(probability: 1.0, sizes: [4.0, 4.0], horizon: 7, paths: 300, seed: 5).totals
    assert_equal Array.new(300, 28.0), totals
  end

  def test_an_all_zero_history_gives_zero_quantiles
    [[0.0], [0.0, -0.0, 0.0], Array.new(30, 0.0)].each do |values|
      NAMES.each do |name|
        model = Foresight::MODELS.fetch(name).new(values, OPTIONS)
        strategy = Foresight::CompoundStrategy.new(model, horizon: 6, levels: EXAMPLE_LEVELS, paths: 50, seed: 0)
        about = "#{name} on #{safe_inspect(values)}"

        assert_equal [0.0, []], [model.probability, model.sizes], about
        assert_equal EXAMPLE_LEVELS.to_h { |level| [level, Array.new(6, 0.0)] }, strategy.quantiles, about
        assert_equal EXAMPLE_LEVELS.to_h { |level| [level, 0.0] }, strategy.lead_time_quantiles, about
      end
    end
    [0.0, 0.5, 1.0].each do |probability|
      totals = Foresight::Simulator.new(probability: probability, sizes: [], horizon: 6, paths: 50, seed: 0).totals
      assert_equal Array.new(50, 0.0), totals, probability.inspect
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

  def history(random)
    size = random.rand < 0.1 ? random.rand(100..200) : random.rand(1..40)
    Generators.numbers(random, size).map(&:to_f)
  end

  def summable_history(random)
    unit = 2.0**random.rand(-3..10)
    chance = [0.0, 0.1, 0.3, 0.6, 1.0].sample(random: random)
    Array.new(random.rand(1..40)) { random.rand < chance ? unit * random.rand(1..100) : 0.0 }
  end

  def small_history(random)
    chance = random.rand(0.1..1.0)
    largest = random.rand(1..9)
    Array.new(random.rand(1..12)) { random.rand < chance ? random.rand(1..largest).to_f : 0.0 }
  end

  def draw_options(random)
    { alpha: parameter(random), alpha_d: parameter(random), alpha_p: parameter(random) }
  end

  def parameter(random)
    case random.rand(10)
    when 0 then 0.1
    when 1 then [1e-9, 1 - 1e-9].sample(random: random)
    when 2, 3 then Rational(random.rand(1..999), 1000)
    else random.rand(0.001..0.999)
    end
  end

  def random_levels(random)
    Array.new(random.rand(1..6)) do
      case random.rand(8)
      when 0 then EDGE_LEVELS.sample(random: random)
      when 1, 2 then Foresight::DEFAULT_LEVELS.sample(random: random)
      when 3, 4 then Rational(random.rand(1..999), 1000)
      else random.rand(1e-6..1 - 1e-6)
      end
    end
  end

  def boundary_levels(random, probability, count)
    chance = probability.to_r
    return [] if chance.zero? || count.zero? || random.rand < 0.5

    jump = random.rand(1..count)
    levels = [1 - chance + chance * Rational(2 * jump - 1, 2 * count)]
    levels << 1 - chance + chance * Rational(jump, count) if jump < count
    levels << 1 - chance if chance < 1
    levels
  end

  def rank_levels(random, paths)
    return [] if paths == 1 || random.rand < 0.5

    [Rational(random.rand(1...paths), paths)]
  end

  def sorted_levels(levels)
    levels.uniq(&:to_r).sort
  end

  def mass(distribution)
    distribution.sum { |total, chance| yield(total) ? chance : 0 }
  end

  def inside_margin?(gap, paths)
    gap <= 0 || gap * gap * paths <= MARGIN * MARGIN
  end
end
