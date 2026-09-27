# frozen_string_literal: true

require "test_helper"
require "oracles"
require "foresight"

class ConformalStrategyTest < Minitest::Test
  SEED = 67_867_967
  LIMIT = 1e6
  NAMES = %i[naive seasonal_naive ses croston_classic croston_sba tsb].freeze
  OPTIONS = { alpha: 0.1, alpha_d: 0.1, alpha_p: 0.1, season_length: 7 }.freeze
  EDGE_LEVELS = [1e-6, 1 - 1e-6].freeze

  def test_quantiles_follow_the_window_construction_on_random_histories
    seen = []
    each_seed(200) do |seed, random|
      values, options, horizon, levels = draw(random)
      windows = options[:windows]
      block = windows * horizon
      about = "seed #{seed}: #{safe_inspect(values)} #{safe_inspect(options)} horizon #{horizon} " \
              "levels #{safe_inspect(levels)}"
      NAMES.each do |name|
        model_class = Foresight::MODELS.fetch(name)
        point = model_class.new(values, options).forecast(horizon)
        strategy = Foresight::ConformalStrategy.new(model_class, values, options,
                                                    horizon: horizon, levels: levels, point: point)
        quantiles = strategy.quantiles
        lead_times = strategy.lead_time_quantiles
        minimum = (name == :seasonal_naive ? options[:season_length] : 1) + block
        where = "#{about}, #{name}"

        assert_equal minimum, Foresight::ConformalStrategy.minimum_history(model_class, options, horizon), where
        assert_equal levels, quantiles.keys, where
        assert_equal levels, lead_times.keys, where
        Oracles.conformal_quantiles(name, values, options, horizon, levels).each do |level, (steps, total)|
          at = "#{where}, level #{level.inspect}"

          assert_equal steps.map { |step| censored(step) }, quantiles[level], at
          assert_equal censored(total), lead_times[level], at
          seen << :censored if [*steps, total].any?(&:negative?)
        end
      end
      seen << :minimum if values.size == block + 1
      seen << :seasonal_minimum if options[:season_length] > 1 && values.size == block + options[:season_length]
      seen << :one_period if horizon == 1
      seen << :wrapped if horizon > options[:season_length]
      seen << :two_windows if windows == 2
      seen << :six_windows if windows == 6
      seen << :zero if values.all?(&:zero?)
      seen << :rational if levels.any?(Rational)
      seen << :exact_rank if levels.any? { |level| (level.to_r * 2 * windows).denominator == 1 }
    end
    assert_equal %i[censored exact_rank minimum one_period rational seasonal_minimum six_windows two_windows wrapped
                    zero], seen.uniq.sort, "seed #{SEED}"
  end

  def test_with_two_windows_the_median_is_the_second_smallest_of_four_values
    values = [20.0, 24.0, 21.0, 30.0, 26.0, 22.0]
    options = OPTIONS.merge(windows: 2)
    levels = [0.25, 0.5, 0.75, 0.95]
    errors = [[(21.0 - 24.0).abs, (26.0 - 30.0).abs], [(30.0 - 24.0).abs, (22.0 - 30.0).abs]]
    total_errors = [(21.0 + 30.0 - 2 * 24.0).abs, (26.0 + 22.0 - 2 * 30.0).abs]
    point = Foresight::Naive.new(values, options).forecast(2)
    strategy = Foresight::ConformalStrategy.new(Foresight::Naive, values, options,
                                                horizon: 2, levels: levels, point: point)

    assert_equal [22.0, 22.0], point
    assert_equal({ 0.25 => [18.0, 14.0], 0.5 => [19.0, 16.0], 0.75 => [25.0, 28.0], 0.95 => [26.0, 30.0] },
                 strategy.quantiles)
    assert_equal({ 0.25 => 32.0, 0.5 => 41.0, 0.75 => 47.0, 0.95 => 56.0 }, strategy.lead_time_quantiles)
    assert_equal errors.map { |period| 22.0 - period.min }, strategy.quantiles[0.5]
    assert_equal 44.0 - total_errors.min, strategy.lead_time_quantiles[0.5]
  end

  def test_automatic_forecasts_refit_the_selected_model_in_every_window
    seen = []
    each_seed(120) do |seed, random|
      call, options = automatic_call(random)
      result = Foresight.forecast(call.input, **options)
      values = Oracles.option_values(options)
      about = "seed #{seed}: #{safe_inspect(call.input)} #{safe_inspect(options)}"
      expected = Oracles.conformal_quantiles(result.model, call.numbers.map(&:to_f), values, values[:count],
                                             values[:levels])

      assert_equal Foresight::Selector::RULE.fetch(Oracles.classification(call.numbers)[:demand_class]),
                   result.model, about
      expected.each do |level, (steps, total)|
        at = "#{about}, level #{level.inspect}"
        table = result.quantiles[level]

        assert_equal steps.map { |step| censored(step) }, Hash === table ? table.values : table, at
        assert_equal censored(total), result.lead_time_quantiles[level], at
      end
      seen << result.model << (call.keys ? :keyed : :array)
      seen << :two_windows if options[:windows] == 2
      seen << :six_windows if options[:windows] == 6
    end
    assert_equal %i[array croston_sba keyed ses six_windows two_windows], seen.uniq.sort, "seed #{SEED}"
  end

  private

  def automatic_call(random)
    windows = random.rand(2..6)
    loop do
      call = Generators.forecast_call(random, model: nil, strategy: :conformal, keyed: random.rand < 0.5)
      options = call.options.merge(windows: windows)
      return [call, options] if call.numbers.size >= Generators.shortest_history(options)
    end
  end

  def each_seed(count)
    rng = Random.new(SEED)
    count.times do
      seed = rng.rand(2**32)
      yield seed, Random.new(seed)
    end
  end

  def draw(random)
    windows = random.rand(2..6)
    horizon = random.rand < 0.2 ? 1 : random.rand(1..12)
    season_length = random.rand < 0.3 ? 1 : random.rand(2..12)
    extra = random.rand < 0.3 ? 0 : random.rand(1..40)
    options = { alpha: parameter(random), alpha_d: parameter(random), alpha_p: parameter(random),
                season_length: season_length, windows: windows, seed: random.rand(2**32) }
    levels = sorted_levels(random_levels(random) + rank_levels(random, windows))
    [history(random, windows * horizon + season_length + extra), options, horizon, levels]
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
    else Generators.numbers(random, size).map { |value| [value.to_f, LIMIT].min }
    end
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

  def rank_levels(random, windows)
    return [] if random.rand < 0.5

    [Rational(random.rand(1...2 * windows), 2 * windows)]
  end

  def sorted_levels(levels)
    levels.uniq(&:to_r).sort
  end

  def censored(value)
    [0.0, value].max
  end
end
