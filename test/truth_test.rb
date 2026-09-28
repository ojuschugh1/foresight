# frozen_string_literal: true

require "test_helper"
require "json"
require_relative "../validation/truth"

class TruthTest < Minitest::Test
  SEED = 179_424_673
  ROOT = File.dirname(__dir__)
  CONFIG_FILE = File.join(ROOT, "validation", "study_config.json")
  TRUTH_FILE = File.join(ROOT, "validation", "truth.rb")
  DEVIATES = { 0.5 => 0.0, 0.8 => 0.841621233573, 0.9 => 1.281551565545, 0.95 => 1.644853626951,
               5e-10 => -6.109410204869 }.freeze
  DEVIATE_TOLERANCE = 2e-12
  QUANTILE_TOLERANCE = 1e-10
  MEAN = 50
  SD = 10
  TOTAL_MEAN = 350
  TOTAL_VARIANCE = 700
  PER_PERIOD = {
    "erratic-bernoulli" => [{ 0 => 1/8r, 1 => 7/16r, 3 => 7/32r, 10 => 7/32r }, [1, 10, 10, 10], [9/16r, 1r, 1r, 1r]],
    "intermittent-bernoulli" => [{ 0 => 3/4r, 1 => 1/20r, 2 => 1/20r, 3 => 1/20r, 4 => 1/20r, 5 => 1/20r },
                                 [0, 2, 4, 4], [3/4r, 17/20r, 19/20r, 19/20r]],
    "lumpy-bernoulli" => [{ 0 => 3/4r, 1 => 1/8r, 3 => 1/16r, 10 => 1/16r }, [0, 1, 3, 10], [3/4r, 7/8r, 15/16r, 1r]]
  }.freeze
  CONFIGURATION = {
    "horizon" => 7, "origins" => 10, "step" => 7,
    "levels" => [0.5, 0.8, 0.9, 0.95],
    "paths" => 10_000, "windows" => 10, "backtest_seed" => 20_260_925,
    "bootstrap" => { "resamples" => 2_000, "seed" => 20_260_926 },
    "processes" => [
      { "name" => "smooth-gaussian", "kind" => "gaussian", "mean" => 50.0, "sd" => 10.0,
        "series" => 50, "length" => 200, "first_seed" => 10_001 },
      { "name" => "erratic-bernoulli", "kind" => "bernoulli", "occurrence" => 0.875,
        "sizes" => [[1, 2], [3, 1], [10, 1]], "series" => 50, "length" => 200, "first_seed" => 20_001 },
      { "name" => "intermittent-bernoulli", "kind" => "bernoulli", "occurrence" => 0.25,
        "sizes" => [[1, 1], [2, 1], [3, 1], [4, 1], [5, 1]], "series" => 50, "length" => 200, "first_seed" => 30_001 },
      { "name" => "lumpy-bernoulli", "kind" => "bernoulli", "occurrence" => 0.25,
        "sizes" => [[1, 2], [3, 1], [10, 1]], "series" => 50, "length" => 200, "first_seed" => 40_001 }
    ]
  }.freeze

  def test_step_and_total_distributions_equal_an_enumeration_of_every_outcome
    seen = []
    each_seed(200) do |seed, random|
      occurrence, sizes, horizon = random_process(random)
      about = "seed #{seed}: occurrence #{occurrence.inspect} sizes #{sizes.inspect} horizon #{horizon}"
      step = Truth.step_distribution(occurrence, sizes)
      total = Truth.total_distribution(step, horizon)
      masses = step.values + total.values

      assert_equal enumerated(occurrence, sizes, 1), step, about
      assert_equal enumerated(occurrence, sizes, horizon), total, about
      assert masses.all?(Rational), about
      seen << :one_period if horizon == 1
      seen << :four_periods if horizon == 4
      seen << :one_size if sizes.size == 1
      seen << :five_sizes if sizes.size == 5
    end
    assert_equal %i[five_sizes four_periods one_period one_size], seen.uniq.sort, "seed #{SEED}"
  end

  def test_true_quantiles_are_the_smallest_values_whose_cdf_reaches_the_level
    seen = []
    each_seed(200) do |seed, random|
      occurrence, sizes, horizon = random_process(random)
      step_cdf = cumulative(enumerated(occurrence, sizes, 1))
      total_cdf = cumulative(enumerated(occurrence, sizes, horizon))
      reached = step_cdf.values + total_cdf.values - [1r]
      levels = random_levels(random, reached)
      process = { "kind" => "bernoulli", "occurrence" => occurrence, "sizes" => sizes }
      about = "seed #{seed}: occurrence #{occurrence.inspect} sizes #{sizes.inspect} horizon #{horizon}"
      truths = Truth.quantiles(process, horizon: horizon, levels: levels)

      assert_equal levels.uniq, truths.keys, "#{about} levels #{levels.inspect}"
      truths.each do |level, truth|
        at = "#{about} level #{level.inspect}"

        assert_smallest_reaching(step_cdf, truth.step_quantile, level, at)
        assert_smallest_reaching(total_cdf, truth.total_quantile, level, at)
        assert_equal [step_cdf[truth.step_quantile], total_cdf[truth.total_quantile]],
                     [truth.step_probability, truth.total_probability], at
        assert [truth.step_probability, truth.total_probability].all?(Rational), at
        seen << tie(level, reached)
        seen << :float_level if Float === level
        seen << :zero_quantile if truth.step_quantile.zero?
        seen << :largest_size if truth.step_quantile == sizes.map(&:first).max
      end
    end
    assert_equal %i[exact_tie float_level largest_size rounded_tie zero_quantile], seen.compact.uniq.sort,
                 "seed #{SEED}"
  end

  def test_gaussian_truths_match_published_normal_quantiles
    config = committed_configuration
    process = config["processes"].find { |candidate| candidate["kind"] == "gaussian" }
    truths = Truth.quantiles(process, horizon: config["horizon"], levels: DEVIATES.keys)

    DEVIATES.each do |level, deviate|
      truth = truths[level]
      about = "level #{level.inspect}"

      assert_in_delta deviate, Truth.normal_quantile(level), DEVIATE_TOLERANCE, about
      assert_in_delta [0, MEAN + SD * deviate].max, truth.step_quantile, QUANTILE_TOLERANCE, about
      assert_in_delta TOTAL_MEAN + Math.sqrt(TOTAL_VARIANCE) * deviate, truth.total_quantile, QUANTILE_TOLERANCE,
                      about
      assert_nil truth.step_probability, about
      assert_nil truth.total_probability, about
    end
    assert_equal 0.0, truths[5e-10].step_quantile
  end

  def test_committed_bernoulli_processes_have_the_hand_computed_per_period_truths
    config = committed_configuration
    PER_PERIOD.each do |name, (distribution, quantiles, probabilities)|
      process = config["processes"].find { |candidate| candidate["name"] == name }
      truths = Truth.quantiles(process, horizon: config["horizon"], levels: config["levels"]).values

      assert_equal distribution, Truth.step_distribution(process["occurrence"], process["sizes"]), name
      assert_equal quantiles, truths.map(&:step_quantile), name
      assert_equal probabilities, truths.map(&:step_probability), name
    end
  end

  def test_a_double_level_is_compared_with_the_cdf_at_its_exact_binary_value
    process = { "kind" => "bernoulli", "occurrence" => 1/4r, "sizes" => [[1, 1], [2, 1], [3, 1], [4, 1], [5, 1]] }
    decimals = [4/5r, 9/10r, 19/20r]
    doubles = [0.8, 0.9, 0.95]
    exact = Truth.quantiles(process, horizon: 1, levels: decimals).values
    rounded = Truth.quantiles(process, horizon: 1, levels: doubles).values

    assert_equal decimals, exact.map(&:step_probability)
    assert_equal [1, 3, 4], exact.map(&:step_quantile)
    assert_equal [2, 4, 4], rounded.map(&:step_quantile)
    assert_equal [1, 1, -1], doubles.zip(decimals).map { |double, decimal| double.to_r <=> decimal }
  end

  def test_the_study_configuration_holds_the_planned_settings
    config = committed_configuration

    assert_equal CONFIGURATION, config
    assert_equal classes(CONFIGURATION), classes(config)
  end

  def test_true_quantiles_are_computed_without_loading_the_gem
    script = <<~RUBY
      require "json"
      require #{TRUTH_FILE.inspect}
      config = JSON.parse(File.read(#{CONFIG_FILE.inspect}))
      config["processes"].each do |process|
        Truth.quantiles(process, horizon: config["horizon"], levels: config["levels"])
      end
      puts defined?(Foresight).inspect
    RUBY
    output, error, status = run_ruby("-I", File.join(ROOT, "lib"), "-e", script)

    assert status.success?, error
    assert_equal "nil\n", output
  end

  private

  def each_seed(count)
    rng = Random.new(SEED)
    count.times do
      seed = rng.rand(2**32)
      yield seed, Random.new(seed)
    end
  end

  def committed_configuration
    JSON.parse(File.read(CONFIG_FILE))
  rescue JSON::ParserError => e
    flunk "#{CONFIG_FILE} does not parse: #{e.message}"
  end

  def random_process(random)
    denominator = random.rand(2..64)
    occurrence = Rational(random.rand(1...denominator), denominator)
    sizes = (1..20).to_a.sample(random.rand(1..5), random: random).map { |size| [size, random.rand(1..9)] }
    [occurrence, sizes, random.rand(1..4)]
  end

  def random_levels(random, reached)
    Array.new(random.rand(1..6)) do
      case random.rand(6)
      when 0 then Rational(random.rand(1..999), 1000)
      when 1 then random.rand(1e-9..(1 - 1e-9))
      when 2 then CONFIGURATION["levels"].sample(random: random)
      when 3, 4 then reached.sample(random: random)
      else reached.sample(random: random).to_f
      end
    end
  end

  def enumerated(occurrence, sizes, horizon)
    total_weight = sizes.sum(&:last)
    outcomes = [[0, 1 - occurrence], *sizes.map { |size, weight| [size, occurrence * Rational(weight, total_weight)] }]
    distribution = Hash.new(0r)
    outcomes.repeated_permutation(horizon) do |path|
      distribution[path.sum(&:first)] += path.map(&:last).inject(:*)
    end
    distribution
  end

  def cumulative(distribution)
    running = 0r
    distribution.sort.to_h { |value, mass| [value, running += mass] }
  end

  def tie(level, reached)
    if reached.include?(level.to_r)
      :exact_tie
    elsif Float === level && reached.any? { |chance| chance.to_f == level }
      :rounded_tie
    end
  end

  def assert_smallest_reaching(cdf, quantile, level, about)
    threshold = level.to_r

    assert cdf.key?(quantile), about
    assert_operator cdf[quantile], :>=, threshold, about
    assert(cdf.all? { |value, chance| value >= quantile || chance < threshold }, about)
  end

  def classes(node)
    case node
    when Hash then node.transform_values { |value| classes(value) }
    when Array then node.map { |value| classes(value) }
    else node.class
    end
  end
end
