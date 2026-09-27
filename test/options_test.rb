# frozen_string_literal: true

require "test_helper"
require "oracles"
require "foresight"

class OptionsTest < Minitest::Test
  SEED = 73_604_155
  CONDITIONAL = %i[seed season_length paths windows alpha alpha_d alpha_p].freeze
  EXAMPLE = [0, 3, 0, 0, 17, 0, 42, 5, 0, 101, 0, 0, 250, 7, 0, 19].freeze
  DEFAULTS = { count: 10, model: nil, levels: [0.5, 0.8, 0.9, 0.95], strategy: :distribution, seed: 0,
               season_length: nil, paths: 10_000, windows: 2, alpha: 0.1, alpha_d: 0.1, alpha_p: 0.1 }.freeze
  ACCEPTED_OPTIONS = ":count, :model, :levels, :strategy, :seed, :season_length, :paths, :windows, :alpha, " \
                     ":alpha_d, :alpha_p"
  ACCEPTED_MODELS = ":naive, :seasonal_naive, :ses, :croston_classic, :croston_sba, :tsb"
  LEVELS = "levels must be a non-empty Array of numbers strictly between 0 and 1"
  SMOOTHING = "must be a finite real number strictly between 0 and 1, got"
  SEASONAL = "SeasonalNaive requires a positive Integer season_length, got"
  MESSAGES = [
    [{ count: 5.0 }, "count must be a positive Integer, got 5.0"],
    [{ count: 0, model: :arima }, "count must be a positive Integer, got 0"],
    [{ horizon: 3 }, "unknown option :horizon; accepted options are #{ACCEPTED_OPTIONS}"],
    [{ "count" => 3 }, "unknown option \"count\"; accepted options are #{ACCEPTED_OPTIONS}"],
    [{ count: 0, nil => 1 }, "unknown option nil; accepted options are #{ACCEPTED_OPTIONS}"],
    [{ 7 => nil }, "unknown option 7; accepted options are #{ACCEPTED_OPTIONS}"],
    [{ OpaqueObject.new => 1 }, "unknown option #<OpaqueObject>; accepted options are #{ACCEPTED_OPTIONS}"],
    [{ model: :arima }, "model :arima is not provided; accepted values are #{ACCEPTED_MODELS}"],
    [{ model: "ses" }, "model \"ses\" is not provided; accepted values are #{ACCEPTED_MODELS}"],
    [{ model: false }, "model false is not provided; accepted values are #{ACCEPTED_MODELS}"],
    [{ levels: [] }, LEVELS],
    [{ levels: 0.5, strategy: :gaussian }, LEVELS],
    [{ levels: [0.5, 1, 0] }, "quantile level 1 must be strictly between 0 and 1"],
    [{ levels: [0.5, Complex(0.5, 0)] }, "quantile level (0.5+0i) must be strictly between 0 and 1"],
    [{ levels: [0.9, OpaqueObject.new] }, "quantile level #<OpaqueObject> must be strictly between 0 and 1"],
    [{ strategy: :gaussian }, "strategy must be :distribution or :conformal, got :gaussian"],
    [{ seed: -1 }, "seed must be a non-negative Integer, got -1"],
    [{ model: :seasonal_naive }, "#{SEASONAL} none"],
    [{ model: :seasonal_naive, season_length: nil }, "#{SEASONAL} none"],
    [{ model: :seasonal_naive, season_length: 0 }, "#{SEASONAL} 0"],
    [{ model: :ses, season_length: 0 }, "season_length must be a positive Integer, got 0"],
    [{ season_length: 2.5 }, "season_length must be a positive Integer, got 2.5"],
    [{ paths: 0 }, "paths must be a positive Integer, got 0"],
    [{ windows: 1 }, "windows must be an Integer of at least 2, got 1"],
    [{ alpha: 1 }, "alpha #{SMOOTHING} 1"],
    [{ alpha_d: Float::NAN }, "alpha_d #{SMOOTHING} NaN"],
    [{ alpha_p: false }, "alpha_p #{SMOOTHING} false"],
    [{ alpha_p: 0, alpha: Float::INFINITY }, "alpha #{SMOOTHING} Infinity"]
  ].freeze

  def test_invalid_options_raise_the_first_failed_check_before_the_series_is_parsed
    seen = []
    each_seed(400) do |seed, random|
      options = Generators.invalid_options(random)
      broken = random.rand < 0.4
      series = broken ? Generators.invalid_series(random).first : random_call(random).input
      check, message = Oracles.option_error(options)
      about = "seed #{seed}: #{safe_inspect(series)} #{safe_inspect(options)}"

      refute_nil message, about
      error = assert_raises(Foresight::InputError, about) { Foresight.forecast(series, **options) }
      assert_equal message, error.message, about
      seen << check
      seen << :none if message.end_with?("got none")
      seen << :false_value if message.end_with?("got false")
      seen << :broken_series if broken
      seen << :nil_unknown if check == :unknown && NilClass === unknown_option(options).last
      seen << :"unread_#{check}" if unread?(check, options)
    end
    expected = %i[unknown count model levels level strategy seed seasonal_naive season_length paths windows alpha
                  alpha_d alpha_p none false_value broken_series nil_unknown]
    expected += CONDITIONAL.map { |name| :"unread_#{name}" }
    assert_equal expected.sort, seen.uniq.sort, "seed #{SEED}"
  end

  def test_a_nil_option_is_the_same_as_an_omitted_one
    seen = []
    each_seed(200) do |seed, random|
      call = random_call(random)
      names = (Generators::OPTION_NAMES - [:paths]).select { random.rand < 0.3 }
      names << :paths if paths_unread?(call.options, names) && random.rand < 0.5
      with_nils = call.options.merge(names.to_h { |name| [name, nil] })
      omitted = call.options.reject { |name, value| names.include?(name) || value.nil? }
      about = "seed #{seed}: #{safe_inspect(call.input)} #{safe_inspect(with_nils)} #{safe_inspect(omitted)}"
      failure = Oracles.option_error(omitted)
      normal = Oracles.option_values(omitted) unless failure

      [with_nils, omitted].each do |options|
        if failure
          error = assert_raises(Foresight::InputError, about) { Foresight::Options.forecast(options) }
          assert_equal failure.last, error.message, about
        else
          values = Foresight::Options.forecast(options)
          assert_equal normal, values, about
          assert_equal normal[:levels].map(&:class), values[:levels].map(&:class), about
          assert_predicate values, :frozen?, about
        end
      end
      outcomes = [with_nils, omitted].map { |options| outcome(call.input, options) }
      assert_equal outcomes.first, outcomes.last, about
      seen.concat(names)
      seen << (Foresight::Result === outcomes.first ? :result : :error)
      seen << :option_error if failure
      seen << :duplicate_levels if normal && omitted.fetch(:levels, []).size > normal[:levels].size
    end
    expected = Generators::OPTION_NAMES + %i[result error option_error duplicate_levels]
    assert_equal expected.sort, seen.uniq.sort, "seed #{SEED}"
  end

  def test_options_the_model_and_strategy_do_not_read_leave_the_result_unchanged
    seen = []
    each_seed(200) do |seed, random|
      call = random_call(random)
      result = Foresight.forecast(call.input, **call.options)
      unread = Generators::OPTION_NAMES - Oracles.options_read(result.model, result.strategy)
      names = unread.sample(random.rand(1..unread.size), random: random)
      options = call.options.merge(names.to_h { |name| [name, Generators.option_value(random, name)] })
      about = "seed #{seed}: #{safe_inspect(call.input)} #{safe_inspect(options)}, #{result.model} " \
              "under #{result.strategy}"

      assert_equal result, Foresight.forecast(call.input, **options), about
      seen.concat(names)
      seen << :automatic if call.options[:model].nil?
      seen << :keyed if call.keys
    end
    expected = CONDITIONAL + %i[automatic keyed]
    assert_equal expected.sort, seen.uniq.sort, "seed #{SEED}"
  end

  def test_seed_and_paths_change_only_the_simulated_lead_time_quantiles
    seen = []
    each_seed(150) do |seed, random|
      model = [nil, *Generators::INTERMITTENT_NAMES].sample(random: random)
      call = Generators.forecast_call(random, model: model, strategy: :distribution, keyed: random.rand < 0.5)
      names = [%i[seed], %i[paths], %i[seed paths]].sample(random: random)
      current = Oracles.option_values(call.options)
      options = call.options.merge(names.to_h { |name| [name, changed_value(random, name, current[name])] })
      result = Foresight.forecast(call.input, **call.options)
      other = Foresight.forecast(call.input, **options)
      about = "seed #{seed}: #{safe_inspect(call.input)} #{safe_inspect(call.options)} #{safe_inspect(options)}"

      if result.model == :ses
        assert_equal result, other, about
      else
        assert_equal result.to_h.except(:lead_time_quantiles), other.to_h.except(:lead_time_quantiles), about
        seen << :changed unless result.lead_time_quantiles == other.lead_time_quantiles
      end
      seen << result.model
      seen.concat(names)
    end
    assert_equal %i[changed croston_classic croston_sba paths seed ses tsb], seen.uniq.sort, "seed #{SEED}"
  end

  def test_omitted_options_take_their_default_values
    assert_equal DEFAULTS, Foresight::Options.forecast({})
    assert_predicate Foresight::Options.forecast({}), :frozen?
    assert_equal DEFAULTS, Foresight::Options.forecast(DEFAULTS.transform_values { nil })
    assert_equal DEFAULTS, Oracles.option_values({})
    series = EXAMPLE * 2
    explicit = DEFAULTS.compact
    [nil, *Generators::MODEL_NAMES].product(Generators::STRATEGY_NAMES).each do |model, strategy|
      options = { model: model, strategy: strategy, season_length: model == :seasonal_naive ? 4 : nil }

      assert_equal Foresight.forecast(series, **options), Foresight.forecast(series, **explicit.merge(options)),
                   "#{model.inspect} under #{strategy}"
    end
  end

  def test_default_seed_and_paths_differ_from_other_values_only_in_lead_time_quantiles
    default = Foresight.forecast(EXAMPLE, model: :croston_sba)

    assert_equal default, Foresight.forecast(EXAMPLE, model: :croston_sba, seed: 0, paths: 10_000)
    [{ paths: 1_000 }, { seed: 1 }].each do |options|
      other = Foresight.forecast(EXAMPLE, model: :croston_sba, **options)

      assert_equal default.to_h.except(:lead_time_quantiles), other.to_h.except(:lead_time_quantiles), options.inspect
      refute_equal default.lead_time_quantiles, other.lead_time_quantiles, options.inspect
    end
  end

  def test_default_windows_and_smoothing_parameters_differ_from_other_values
    options = { model: :croston_sba, strategy: :conformal, count: 4 }
    conformal = Foresight.forecast(EXAMPLE, **options)
    three = Foresight.forecast(EXAMPLE, **options, windows: 3)

    assert_equal conformal, Foresight.forecast(EXAMPLE, **options, windows: 2)
    assert_equal conformal.forecast, three.forecast
    refute_equal conformal.quantiles, three.quantiles
    { croston_classic: %i[alpha], tsb: %i[alpha_d alpha_p] }.each do |model, names|
      default = Foresight.forecast(EXAMPLE, model: model)
      explicit = Foresight.forecast(EXAMPLE, model: model, **names.to_h { |name| [name, 0.1] })

      assert_equal default, explicit, model.inspect
      names.each do |name|
        refute_equal default.forecast, Foresight.forecast(EXAMPLE, model: model, name => 0.3).forecast, name.inspect
      end
    end
  end

  def test_levels_keep_the_first_of_equal_values_in_ascending_order
    result = Foresight.forecast([1, 2, 3], model: :naive, levels: [0.9, Rational(1, 2), 0.5, 0.9, 1e-6])

    assert_equal [1e-6, Rational(1, 2), 0.9], result.levels
    assert_equal [Float, Rational, Float], result.levels.map(&:class)
    assert_equal result.levels, result.quantiles.keys
  end

  def test_each_rejected_option_has_its_own_message
    MESSAGES.each do |options, message|
      about = safe_inspect(options)

      assert_equal message, Oracles.option_error(options).last, about
      [[1, 2, 3], "1, 2, 3"].each do |series|
        error = assert_raises(Foresight::InputError, about) { Foresight.forecast(series, **options) }
        assert_equal message, error.message, about
      end
    end
  end

  def test_each_rejected_backtest_option_has_its_own_message
    unknown = "unknown option :count; accepted options are :horizon, :origins, :step, :model, :levels, " \
              ":strategy, :seed, :season_length, :paths, :windows, :alpha, :alpha_d, :alpha_p"
    shared = %i[model levels strategy seed season_length paths windows alpha alpha_d alpha_p]
    reused = MESSAGES.select { |options, _| options.keys.all? { |name| shared.include?(name) } }
    table = [
      [{}, "horizon is required"],
      [{ horizon: nil, origins: 2 }, "horizon is required"],
      [{ horizon: 2 }, "origins is required"],
      [{ horizon: 0, origins: 2 }, "horizon must be a positive Integer, got 0"],
      [{ horizon: 2, origins: 0 }, "origins must be a positive Integer, got 0"],
      [{ horizon: 2, origins: 1, step: 0 }, "step must be a positive Integer, got 0"],
      [{ horizon: 2, origins: 1, step: -1 }, "step must be a positive Integer, got -1"],
      [{ count: 3 }, unknown],
      [{ horizon: 2, origins: 1, count: 3 }, unknown],
      [{ horizon: 2, origins: 1, step: 0, model: :arima }, "step must be a positive Integer, got 0"],
      *reused.map { |options, message| [{ horizon: 2, origins: 3 }.merge(options), message] }
    ]

    assert_equal 21, reused.size
    table.each do |options, message|
      about = safe_inspect(options)
      [[1, 2, 3], "1, 2, 3", [1, -2, 3]].each do |series|
        error = assert_raises(Foresight::InputError, about) { Foresight.backtest(series, **options) }
        assert_equal message, error.message, about
      end
    end
  end

  def test_the_backtest_step_defaults_to_the_horizon
    assert_equal 3, Foresight::Options.backtest({ horizon: 3, origins: 2 })[:step]
    [nil, *Generators::MODEL_NAMES].product(Generators::STRATEGY_NAMES).each do |model, strategy|
      options = { horizon: 3, origins: 2, model: model, strategy: strategy, paths: 200 }
      options[:season_length] = 4 if model == :seasonal_naive
      about = safe_inspect(options)
      expected = Foresight.backtest(EXAMPLE * 3, **options)

      [nil, 3].each { |step| assert_equal expected, Foresight.backtest(EXAMPLE * 3, **options, step: step), about }
      shifted = Foresight.backtest(EXAMPLE * 3, **options, step: 1)
      refute_equal expected.origins.map(&:start), shifted.origins.map(&:start), about
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

  def random_call(random)
    Generators.forecast_call(random, model: [nil, *Generators::MODEL_NAMES].sample(random: random),
                                     strategy: Generators::STRATEGY_NAMES.sample(random: random),
                                     keyed: random.rand < 0.5)
  end

  def changed_value(random, name, current)
    loop do
      value = Generators.option_value(random, name)
      return value unless value == current
    end
  end

  def outcome(input, options)
    Foresight.forecast(input, **options)
  rescue Foresight::InputError => e
    e.message
  end

  def paths_unread?(options, cleared)
    model = cleared.include?(:model) ? nil : options[:model]
    strategy = cleared.include?(:strategy) ? nil : options[:strategy]
    strategy == :conformal || %i[naive seasonal_naive ses].include?(model)
  end

  def unknown_option(options)
    options.each_pair.find { |name, _| !Generators::OPTION_NAMES.include?(name) }
  end

  def unread?(check, options)
    model = options[:model]
    return false unless CONDITIONAL.include?(check) && !model.nil?

    !Oracles.options_read(model, options[:strategy] || :distribution).include?(check)
  end
end
