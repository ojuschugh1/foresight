# frozen_string_literal: true

require "test_helper"
require "oracles"
require "foresight"

class ModelsTest < Minitest::Test
  SEED = 104_729
  LIMIT = 1e6
  NAMES = %i[naive seasonal_naive ses croston_classic croston_sba tsb].freeze
  FLAT = %i[ses croston_classic croston_sba tsb].freeze
  INTERMITTENT = %i[croston_classic croston_sba tsb].freeze
  OPTIONS = { alpha: 0.1, alpha_d: 0.1, alpha_p: 0.1, season_length: 7 }.freeze
  ZEROS = [0, 0.0, -0.0, Rational(0)].freeze

  def test_point_forecasts_match_the_oracle_on_random_histories
    seen = []
    each_seed(300) do |seed, random|
      values, options, horizon = draw(random)
      about = details(seed, values, options, horizon)
      NAMES.each do |name|
        forecast = Foresight::MODELS.fetch(name).new(values, options).forecast(horizon)
        assert_identical Oracles.point_forecasts(name, values, options, horizon), forecast, "#{about}, #{name}"
      end
      seen << :zero if values.all?(&:zero?)
      seen << :single if values.size == 1
      seen << :long if values.size >= 200
      seen << :wrapped if horizon > options[:season_length]
      seen << :rational if options.values_at(:alpha, :alpha_d, :alpha_p).any?(Rational)
    end
    assert_equal %i[long rational single wrapped zero], seen.uniq.sort, "seed #{SEED}"
  end

  def test_ses_and_the_croston_family_forecast_one_value_for_every_period
    each_seed(200) do |seed, random|
      values, options, horizon = draw(random)
      about = details(seed, values, options, horizon)
      FLAT.each do |name|
        forecast = Foresight::MODELS.fetch(name).new(values, options).forecast(horizon)
        assert_equal Array.new(horizon, forecast.first), forecast, "#{about}, #{name}"
      end
    end
  end

  def test_the_ses_parameter_stays_within_the_search_interval
    edges = []
    each_seed(200) do |seed, random|
      values = history(random)
      about = "seed #{seed}: #{safe_inspect(values)}"
      alpha = Foresight::SES.new(values, OPTIONS).alpha

      assert_instance_of Float, alpha, about
      assert_operator alpha, :>=, 0.01, about
      assert_operator alpha, :<=, 0.99, about
      assert_equal Oracles.ses_alpha(values), alpha, about
      edges << :lower if alpha < 0.01 + 1e-9
      edges << :upper if alpha > 0.99 - 1e-9
    end
    assert_equal %i[lower upper], edges.uniq.sort, "seed #{SEED}"
  end

  def test_intermittent_models_forecast_zero_on_all_zero_histories
    each_seed(200) do |seed, random|
      values = Array.new([Generators.run_length(random), 1].max) { Generators.number(random, 0, :mixed).to_f }
      options = draw_options(random, values.size)
      horizon = random.rand(1..60)
      about = details(seed, values, options, horizon)
      INTERMITTENT.each do |name|
        forecast = Foresight::MODELS.fetch(name).new(values, options).forecast(horizon)
        assert_equal Array.new(horizon, 0.0), forecast, "#{about}, #{name}"
      end
    end
  end

  def test_models_maps_the_six_symbols_to_their_classes
    expected = { naive: Foresight::Naive, seasonal_naive: Foresight::SeasonalNaive, ses: Foresight::SES,
                 croston_classic: Foresight::CrostonClassic, croston_sba: Foresight::CrostonSBA,
                 tsb: Foresight::TSB }

    assert_equal expected, Foresight::MODELS
    assert_predicate Foresight::MODELS, :frozen?
    assert_equal({ naive: 1, seasonal_naive: 7, ses: 1, croston_classic: 1, croston_sba: 1, tsb: 1 },
                 Foresight::MODELS.transform_values { |model| model.minimum_history(OPTIONS) })
  end

  def test_ses_settles_on_one_half_for_an_all_zero_series
    [[0.0], [0.0, -0.0], Array.new(40, 0.0)].each do |values|
      model = Foresight::SES.new(values, OPTIONS)

      assert_equal 0.5, model.alpha, safe_inspect(values)
      assert_equal [0.0, 0.0, 0.0], model.forecast(3), safe_inspect(values)
    end
  end

  def test_the_sba_factor_at_one_tenth_is_the_double_0_95
    values = [0.0, 0.0, 4.0, 0.0, 6.0, 0.0, 0.0, 0.0, 3.0]
    [0.1, Rational(1, 10)].each do |alpha|
      options = OPTIONS.merge(alpha: alpha)
      classic = Foresight::CrostonClassic.new(values, options).forecast(3)

      assert_equal [0.95, 0.95, 0.95], Foresight::CrostonSBA.new([1.0], options).forecast(3), alpha.inspect
      assert_equal classic.map { |value| 0.95 * value }, Foresight::CrostonSBA.new(values, options).forecast(3),
                   alpha.inspect
    end
  end

  def test_seasonal_naive_refuses_a_history_shorter_than_its_season
    [[2, 1], [7, 1], [7, 6], [12, 11], [52, 30]].each do |season_length, size|
      options = OPTIONS.merge(season_length: season_length)
      error = assert_raises(Foresight::InputError) { Foresight::SeasonalNaive.new(Array.new(size, 1.0), options) }

      assert_equal "SeasonalNaive requires at least #{season_length} observations (its season_length), got #{size}",
                   error.message
      assert_nil Foresight::SeasonalNaive.check_history(season_length, options)
      assert_nil Foresight::SeasonalNaive.check_history(season_length + size, options)
    end
  end

  def test_point_forecasts_and_the_reported_model_do_not_depend_on_the_strategy
    seen = []
    each_seed(150) do |seed, random|
      model = [nil, *NAMES].sample(random: random)
      call = Generators.forecast_call(random, model: model, strategy: :conformal, keyed: random.rand < 0.5)
      about = "seed #{seed}: #{safe_inspect(call.input)} #{safe_inspect(call.options)}"
      conformal = Foresight.forecast(call.input, **call.options)
      distribution = Foresight.forecast(call.input, **call.options.merge(strategy: :distribution))

      assert_equal :conformal, conformal.strategy, about
      assert_equal :distribution, distribution.strategy, about
      assert_equal conformal.model, distribution.model, about
      assert_equal conformal.forecast, distribution.forecast, about
      assert_identical steps(conformal.forecast), steps(distribution.forecast), about
      seen << (model || :automatic) << (call.keys ? :keyed : :array)
    end
    assert_equal [:array, :automatic, :keyed, *NAMES].sort, seen.uniq.sort, "seed #{SEED}"
  end

  def test_all_zero_series_give_zero_forecasts_and_quantiles_under_every_model_and_strategy
    seen = []
    each_seed(100) do |seed, random|
      options = Generators.forecast_options(random, :seasonal_naive, :conformal)
      options[:paths] = Generators.option_value(random, :paths)
      size = Generators.shortest_history(options) + Generators.extra_length(random)
      zeros = Array.new(size) { ZEROS.sample(random: random) }
      input = random.rand < 0.5 ? zeros : Generators.forecast_keys(random, size).zip(zeros).shuffle(random: random).to_h
      values = Oracles.option_values(options)
      expected = Array.new(values[:count], 0.0)
      about = "seed #{seed}: #{safe_inspect(input)} #{safe_inspect(options)}"
      NAMES.product(Generators::STRATEGY_NAMES).each do |name, strategy|
        result = Foresight.forecast(input, **options.merge(model: name, strategy: strategy))
        where = "#{about}, #{name} under #{strategy}"

        assert_equal expected, steps(result.forecast), where
        assert_equal values[:levels].size, result.quantiles.size, where
        result.quantiles.each_value { |table| assert_equal expected, steps(table), where }
        assert_equal Array.new(values[:levels].size, 0.0), result.lead_time_quantiles.values, where
        assert_nil result.demand_class, where
        assert_equal "#{name} was specified by the caller", result.reason, where
      end
      seen << (Hash === input ? :keyed : :array)
    end
    assert_equal %i[array keyed], seen.uniq.sort, "seed #{SEED}"
  end

  private

  def steps(table)
    Hash === table ? table.values : table
  end

  def each_seed(count)
    rng = Random.new(SEED)
    count.times do
      seed = rng.rand(2**32)
      yield seed, Random.new(seed)
    end
  end

  def draw(random)
    values = history(random)
    options = draw_options(random, values.size)
    [values, options, horizon(random, options[:season_length])]
  end

  def history(random)
    size = [Generators.run_length(random), 1].max
    case random.rand(10)
    when 0
      start = random.rand(0.0..50.0)
      slope = random.rand(0.5..5.0)
      Array.new(size) { |index| start + slope * index }
    when 1
      center = random.rand(10.0..100.0)
      spread = random.rand(0.5..5.0)
      Array.new(size) { |index| index.zero? ? center : center + (index.odd? ? spread : -spread) }
    else
      Generators.numbers(random, size).map { |value| [value.to_f, LIMIT].min }
    end
  end

  def draw_options(random, size)
    season_length = random.rand < 0.5 ? random.rand(1..size) : [[1, 4, 7, 12, 52].sample(random: random), size].min
    { alpha: parameter(random), alpha_d: parameter(random), alpha_p: parameter(random), season_length: season_length }
  end

  def parameter(random)
    case random.rand(10)
    when 0 then 0.1
    when 1 then [1e-9, 1 - 1e-9].sample(random: random)
    when 2, 3 then Rational(random.rand(1..999), 1000)
    else random.rand(0.001..0.999)
    end
  end

  def horizon(random, season_length)
    random.rand < 0.3 ? random.rand(1..3 * season_length) : random.rand(1..30)
  end

  def details(seed, values, options, horizon)
    "seed #{seed}: #{safe_inspect(values)} #{safe_inspect(options)} horizon #{horizon}"
  end

  def assert_identical(expected, actual, about)
    assert_equal expected, actual, about
    assert_equal expected.pack("G*"), actual.pack("G*"), about
    assert actual.all?(Float), about
  end
end
