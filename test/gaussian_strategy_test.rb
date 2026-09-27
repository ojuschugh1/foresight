# frozen_string_literal: true

require "test_helper"
require "oracles"
require "foresight"

class GaussianStrategyTest < Minitest::Test
  SEED = 32_452_843
  LIMIT = 1e6
  NAMES = %i[naive seasonal_naive ses].freeze
  OPTIONS = { season_length: 7 }.freeze
  RELATIVE = 1e-9
  ABSOLUTE = 1e-12
  SES_RELATIVE = Rational("1e-12")
  EDGE_LEVELS = [1e-6, 1 - 1e-6].freeze
  EXAMPLE_LEVELS = [1e-6, Rational(1, 20), 0.5, 0.95, 1 - 1e-6].freeze

  def test_quantiles_follow_the_error_structure_on_random_histories
    seen = []
    each_seed(200) do |seed, random|
      values, options, horizon, levels = draw(random)
      about = "seed #{seed}: #{safe_inspect(values)} #{safe_inspect(options)} horizon #{horizon} " \
              "levels #{safe_inspect(levels)}"
      NAMES.each do |name|
        model = Foresight::MODELS.fetch(name).new(values, options)
        strategy = Foresight::GaussianStrategy.new(model, horizon: horizon, levels: levels)
        quantiles = strategy.quantiles
        lead_times = strategy.lead_time_quantiles

        assert_equal levels, quantiles.keys, "#{about}, #{name}"
        assert_equal levels, lead_times.keys, "#{about}, #{name}"
        Oracles.gaussian_quantiles(name, values, options, horizon, levels).each do |level, (steps, total)|
          where = "#{about}, #{name}, level #{level.inspect}"
          expected = censored(total)

          assert_equal horizon, quantiles[level].size, where
          assert_empty mismatches(steps.map { |step| censored(step) }, quantiles[level]), where
          assert_in_delta expected, lead_times[level], tolerance(expected), where
          seen << :censored if [*steps, total].any?(&:negative?)
        end
        seen << :zero_variance if model.residuals.all?(&:zero?)
      end
      seen << :minimum if values.size == 2
      seen << :seasonal_minimum if values.size > 2 && values.size == options[:season_length] + 1
      seen << :wrapped if horizon > options[:season_length]
      seen << :rational if levels.any?(Rational)
    end
    assert_equal %i[censored minimum rational seasonal_minimum wrapped zero_variance], seen.uniq.sort, "seed #{SEED}"
  end

  def test_total_factors_sum_every_entry_of_the_error_covariance
    seen = []
    each_seed(150) do |seed, random|
      horizon = random.rand < 0.2 ? [1, 60].sample(random: random) : random.rand(1..60)
      season_length = random.rand < 0.2 ? [1, 12].sample(random: random) : random.rand(1..12)
      values = history(random, random.rand(12..100))
      options = OPTIONS.merge(season_length: season_length)
      ses = Foresight::SES.new(values, options)
      about = "seed #{seed}: horizon #{horizon}, season length #{season_length}, alpha #{ses.alpha.inspect}, " \
              "#{safe_inspect(values)}"
      exact = total(Oracles.error_covariance(:ses, horizon, alpha: ses.alpha.to_r))
      difference = (ses.total_factor(horizon).to_r - exact).abs

      assert_exact total(Oracles.error_covariance(:naive, horizon)),
                   Foresight::Naive.new(values, options).total_factor(horizon), about
      assert_exact total(Oracles.error_covariance(:seasonal_naive, horizon, season_length: season_length)),
                   Foresight::SeasonalNaive.new(values, options).total_factor(horizon), about
      assert_operator difference, :<=, SES_RELATIVE * exact, about
      seen << :one_period if horizon == 1
      seen << :sixty_periods if horizon == 60
      seen << :season_of_one if season_length == 1
      seen << :season_of_twelve if season_length == 12
      seen << :season_beyond_horizon if season_length > horizon
      seen << :lowest_alpha if ses.alpha < 0.01 + 1e-9
      seen << :highest_alpha if ses.alpha > 0.99 - 1e-9
    end
    assert_equal %i[highest_alpha lowest_alpha one_period season_beyond_horizon season_of_one season_of_twelve
                    sixty_periods], seen.uniq.sort, "seed #{SEED}"
  end

  def test_zero_residual_variance_gives_the_point_forecasts_at_every_level
    [
      [:naive, Array.new(9, 5.0), OPTIONS, Array.new(8, 5.0)],
      [:naive, [0.0, 0.0], OPTIONS, Array.new(8, 0.0)],
      [:seasonal_naive, Array.new(9, 5.0), OPTIONS.merge(season_length: 4), Array.new(8, 5.0)],
      [:seasonal_naive, [2.0, 0.0, 7.5] * 3, OPTIONS.merge(season_length: 3), [2.0, 0.0, 7.5] * 2 + [2.0, 0.0]],
      [:ses, Array.new(9, 12.5), OPTIONS, Array.new(8, 12.5)],
      [:ses, [0.0, 0.0, 0.0], OPTIONS, Array.new(8, 0.0)]
    ].each do |name, values, options, forecast|
      model = Foresight::MODELS.fetch(name).new(values, options)
      strategy = Foresight::GaussianStrategy.new(model, horizon: 8, levels: EXAMPLE_LEVELS)
      about = "#{name} on #{safe_inspect(values)}"

      assert model.residuals.all?(&:zero?), about
      assert_equal EXAMPLE_LEVELS.to_h { |level| [level, forecast] }, strategy.quantiles, about
      assert_equal EXAMPLE_LEVELS.to_h { |level| [level, forecast.sum] }, strategy.lead_time_quantiles, about
    end
  end

  def test_the_minimum_history_is_the_fewest_observations_with_one_residual
    cases = [[Foresight::Naive, OPTIONS, 2], [Foresight::SES, OPTIONS, 2]]
    [1, 2, 7, 12, 52].each do |season_length|
      cases << [Foresight::SeasonalNaive, OPTIONS.merge(season_length: season_length), season_length + 1]
    end
    cases.each do |model_class, options, required|
      values = Array.new(required) { |index| (index % 4).to_f }
      about = "#{model_class} with #{safe_inspect(options)}"

      assert_equal required, Foresight::GaussianStrategy.minimum_history(model_class, options), about
      assert_equal 1, model_class.new(values, options).residuals.size, about
      assert_empty model_class.new(values.drop(1), options).residuals, about
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

  def draw(random)
    values = history(random, [Generators.run_length(random), 2].max)
    most = values.size - 1
    season_length = random.rand < 0.5 ? random.rand(1..most) : [[1, 4, 7, 12, 52].sample(random: random), most].min
    [values, OPTIONS.merge(season_length: season_length), random.rand(1..60), draw_levels(random)]
  end

  def draw_levels(random)
    Array.new(random.rand(1..6)) { draw_level(random) }.uniq(&:to_f).sort
  end

  def draw_level(random)
    case random.rand(8)
    when 0 then EDGE_LEVELS.sample(random: random)
    when 1, 2 then Foresight::DEFAULT_LEVELS.sample(random: random)
    when 3, 4 then Rational(random.rand(1..999), 1000)
    else random.rand(1e-6..1 - 1e-6)
    end
  end

  def history(random, size)
    case random.rand(10)
    when 0
      start = random.rand(0.0..50.0)
      slope = random.rand(0.5..5.0)
      Array.new(size) { |index| start + slope * index }
    when 1
      center = random.rand(10.0..100.0)
      spread = random.rand(0.5..5.0)
      Array.new(size) { |index| index.odd? ? center + spread : center - spread }
    when 2, 3, 4 then local_level(random, size)
    else Generators.numbers(random, size).map { |value| [value.to_f, LIMIT].min }
    end
  end

  def local_level(random, size)
    alpha = random.rand(0.01..0.99)
    level = random.rand(100.0..1000.0)
    scale = random.rand(0.5..10.0)
    Array.new(size) do
      innovation = scale * (random.rand + random.rand + random.rand - 1.5)
      value = level + innovation
      level += alpha * innovation
      [value, 0.0].max
    end
  end

  def censored(value)
    [0.0, value].max
  end

  def tolerance(value)
    RELATIVE * value.abs + ABSOLUTE
  end

  def mismatches(expected, actual)
    expected.zip(actual).each_with_index.filter_map do |(value, returned), index|
      [index + 1, value, returned] unless (returned - value).abs <= tolerance(value)
    end
  end

  def assert_exact(expected, actual, about)
    assert_instance_of Integer, actual, about
    assert_equal expected, actual, about
  end

  def total(matrix)
    matrix.sum(&:sum)
  end
end
