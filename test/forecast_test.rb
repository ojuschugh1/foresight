# frozen_string_literal: true

require "test_helper"
require "oracles"
require "foresight"

class ForecastTest < Minitest::Test
  SEED = 29_631_457
  CLASS_NAMES = { naive: "Naive", ses: "SES", croston_classic: "CrostonClassic", croston_sba: "CrostonSBA",
                  tsb: "TSB" }.freeze
  SMOOTH_MODELS = %i[naive seasonal_naive ses].freeze
  FIELDS = %i[forecast quantiles lead_time_quantiles model demand_class reason strategy levels].freeze

  def test_each_minimum_history_is_checked_in_order_and_met_exactly_at_the_largest_one
    seen = []
    each_seed(300) do |seed, random|
      model = [nil, *Generators::MODEL_NAMES].sample(random: random)
      options = { model: model, strategy: Generators::STRATEGY_NAMES.sample(random: random),
                  count: random.rand(1..12), windows: random.rand(2..4), season_length: random.rand(1..12),
                  paths: 200 }
      sparse = random.rand < 0.5
      keyed = random.rand < 0.5
      history_lengths(options, sparse).each do |size|
        values = history(random, size, sparse)
        input = keyed ? keyed_input(random, values) : values
        about = "seed #{seed}: #{safe_inspect(input)} #{safe_inspect(options)}"
        check, message = history_failure(values, options, keyed)

        if message
          error = assert_raises(Foresight::InputError, about) { Foresight.forecast(input, **options) }
          assert_equal message, error.message, about
          seen << check
        else
          result = Foresight.forecast(input, **options)
          assert_equal model || selected(values), result.model, about
          seen << :"#{model || :automatic}_#{options[:strategy]}"
          seen << :"selected_#{result.model}" unless model
        end
      end
    end
    successes = [nil, *Generators::MODEL_NAMES].product(Generators::STRATEGY_NAMES).map do |model, strategy|
      :"#{model || :automatic}_#{strategy}"
    end
    expected = Generators::MODEL_NAMES + successes + %i[automatic keyed gaussian conformal selected_ses
                                                         selected_croston_sba]
    assert_equal expected.sort, seen.uniq.sort, "seed #{SEED}"
  end

  def test_the_result_carries_every_field_in_its_documented_shape
    seen = []
    each_seed(200) do |seed, random|
      call = random_call(random)
      result = Foresight.forecast(call.input, **call.options)
      values = Oracles.option_values(call.options)
      keys = future_keys(call.keys, values[:count]) if call.keys
      about = "seed #{seed}: #{safe_inspect(call.input)} #{safe_inspect(call.options)}"

      assert_instance_of Foresight::Result, result, about
      assert_equal FIELDS.sort, result.to_h.keys.sort, about
      assert_equal expected_selection(call), [result.model, result.demand_class, result.reason], about
      assert_equal values[:strategy], result.strategy, about
      assert_equal values[:levels].inspect, result.levels.inspect, about
      assert_periods keys, values[:count], result.forecast, about
      [result.quantiles, result.lead_time_quantiles].each do |table|
        assert_instance_of Hash, table, about
        assert_equal result.levels.size, table.size, about
        assert(table.keys.zip(result.levels).all? { |key, level| key.equal?(level) }, about)
      end
      result.quantiles.each_value do |steps|
        assert_periods keys, values[:count], steps, about
        assert_equal result.forecast.keys, steps.keys, about if keys
      end
      assert(result.lead_time_quantiles.each_value.all?(Float), about)
      seen << result.model << result.strategy << (keys ? :keyed : :array)
      seen << :no_demand if result.demand_class.nil?
      seen << :default_levels if call.options[:levels].nil?
    end
    expected = Generators::MODEL_NAMES + Generators::STRATEGY_NAMES + %i[keyed array no_demand default_levels]
    assert_equal expected.sort, seen.uniq.sort, "seed #{SEED}"
  end

  def test_a_keyed_series_forecasts_the_same_numbers_as_its_values_in_key_order
    seen = []
    each_seed(150) do |seed, random|
      call = Generators.forecast_call(random, model: [nil, *Generators::MODEL_NAMES].sample(random: random),
                                              strategy: Generators::STRATEGY_NAMES.sample(random: random),
                                              keyed: true)
      reshuffled = call.input.to_a.shuffle(random: random).to_h
      keyed, again, plain = [call.input, reshuffled, call.numbers].map do |input|
        Foresight.forecast(input, **call.options)
      end
      about = "seed #{seed}: #{safe_inspect(call.input)} #{safe_inspect(reshuffled)} #{safe_inspect(call.options)}"

      assert_equal keyed.inspect, again.inspect, about
      assert_equal plain.to_h.inspect, unkeyed(keyed).inspect, about
      keyed.levels.each do |level|
        keyed.quantiles[level].values.zip(plain.quantiles[level]).each do |from_keys, from_values|
          assert_equal from_values, from_keys, about
        end
      end
      seen << keyed.model << keyed.strategy
    end
    expected = Generators::MODEL_NAMES + Generators::STRATEGY_NAMES
    assert_equal expected.sort, seen.uniq.sort, "seed #{SEED}"
  end

  def test_a_specified_model_is_reported_as_specified_and_forecasts_its_own_points
    seen = []
    each_seed(200) do |seed, random|
      call = random_call(random)
      result = Foresight.forecast(call.input, **call.options)
      values = Oracles.option_values(call.options)
      model = values[:model]
      about = "seed #{seed}: #{safe_inspect(call.input)} #{safe_inspect(call.options)}"

      if model
        expected = Oracles.point_forecasts(model, call.numbers.map(&:to_f), values, values[:count])
        assert_equal model, result.model, about
        assert_equal "#{model} was specified by the caller", result.reason, about
        assert_equal expected, call.keys ? result.forecast.values : result.forecast, about
        seen << model
      else
        named = Foresight.forecast(call.input, **call.options.merge(model: result.model))
        assert_equal "#{result.model} was specified by the caller", named.reason, about
        refute_equal result.reason, named.reason, about
        assert_equal result.to_h.except(:reason).inspect, named.to_h.except(:reason).inspect, about
        seen << :"automatic_#{result.model}"
      end
      seen << (call.keys ? :keyed : :array)
    end
    expected = Generators::MODEL_NAMES + %i[automatic_ses automatic_croston_sba keyed array]
    assert_equal expected.sort, seen.uniq.sort, "seed #{SEED}"
  end

  def test_quantiles_are_finite_non_negative_floats_that_do_not_fall_as_the_level_rises
    seen = []
    each_seed(200) do |seed, random|
      call = random_call(random)
      result = Foresight.forecast(call.input, **call.options)
      about = "seed #{seed}: #{safe_inspect(call.input)} #{safe_inspect(call.options)}"
      columns = result.levels.map do |level|
        steps = result.quantiles[level]
        Hash === steps ? steps.values : steps
      end
      rows = columns.transpose << result.levels.map { |level| result.lead_time_quantiles[level] }

      rows.each do |row|
        assert(row.all? { |value| Float === value && value.finite? && value >= 0 }, about)
        assert(row.each_cons(2).all? { |lower, higher| lower <= higher }, about)
      end
      seen << result.model << result.strategy
      seen << :several_levels if result.levels.size > 1
      seen << :several_periods if rows.size > 2
    end
    expected = Generators::MODEL_NAMES + Generators::STRATEGY_NAMES + %i[several_levels several_periods]
    assert_equal expected.sort, seen.uniq.sort, "seed #{SEED}"
  end

  def test_a_specified_model_on_an_all_zero_series_forecasts_zero_without_a_demand_class
    series = [0, -0.0, Rational(0), 0.0] * 4
    Generators::MODEL_NAMES.product(Generators::STRATEGY_NAMES).each do |model, strategy|
      result = Foresight.forecast(series, model: model, strategy: strategy, count: 3, season_length: 4, paths: 200)
      numbers = result.forecast + result.quantiles.values.flatten + result.lead_time_quantiles.values
      about = "#{model} under #{strategy}"

      assert_equal model, result.model, about
      assert_nil result.demand_class, about
      assert_equal "#{model} was specified by the caller", result.reason, about
      assert_equal strategy, result.strategy, about
      assert_equal 3, result.forecast.size, about
      assert(numbers.all? { |value| Float === value && value.zero? }, about)
    end
  end

  def test_automatic_selection_rejects_an_all_zero_series_after_its_minimum_history
    dated = { Date.new(2026, 1, 1) => 0, Date.new(2026, 1, 2) => -0.0, Date.new(2026, 1, 3) => Rational(0) }
    [[0], [-0.0], [Rational(0), 0.0, -0.0, 0], dated].each do |series|
      error = assert_raises(Foresight::InputError, safe_inspect(series)) { Foresight.forecast(series, paths: 200) }
      assert_equal "automatic selection requires at least one non-zero observation; specify a model instead",
                   error.message, safe_inspect(series)
    end
    error = assert_raises(Foresight::InputError) { Foresight.forecast([], paths: 200) }
    assert_equal "automatic model selection requires at least 1 observations, got 0", error.message
  end

  private

  def unkeyed(result)
    result.to_h.merge(forecast: result.forecast.values, quantiles: result.quantiles.transform_values(&:values))
  end

  def random_call(random)
    Generators.forecast_call(random, model: [nil, *Generators::MODEL_NAMES].sample(random: random),
                                     strategy: Generators::STRATEGY_NAMES.sample(random: random),
                                     keyed: random.rand < 0.5)
  end

  def future_keys(keys, count)
    Generators.future_keys(keys.last, Generators.implied_period(keys[0], keys[1]), count)
  end

  def expected_selection(call)
    model = call.options[:model]
    reason = "#{model} was specified by the caller"
    return [model, nil, reason] if model && call.numbers.all?(&:zero?)

    found = Oracles.classification(call.numbers)
    demand_class = found[:demand_class]
    return [model, demand_class, reason] if model

    chosen = demand_class == :smooth ? :ses : :croston_sba
    [chosen, demand_class, format("auto-selected %s for %s demand (ADI %.2f, CV squared %.2f)", chosen,
                                  demand_class, found[:adi], found[:cv_squared])]
  end

  def assert_periods(keys, count, steps, about)
    if keys
      assert_instance_of Hash, steps, about
      assert_equal keys, steps.keys.map { |key| Time === key ? key.to_r : key }, about
      steps = steps.values
    else
      assert_instance_of Array, steps, about
    end
    assert_equal count, steps.size, about
    assert(steps.all?(Float), about)
  end

  def each_seed(count)
    rng = Random.new(SEED)
    count.times do
      seed = rng.rand(2**32)
      yield seed, Random.new(seed)
    end
  end

  def history_lengths(options, sparse)
    model = options[:model]
    lowest = model_minimum(model, options)
    needed = strategy_minimum(model || (sparse ? :croston_sba : :ses), options).last
    [lowest - 1, (needed - 1 if needed > lowest), [lowest, needed].max].compact.reject(&:negative?)
  end

  def model_minimum(model, options)
    model == :seasonal_naive ? options[:season_length] : 1
  end

  def strategy_minimum(model, options)
    lowest = model_minimum(model, options)
    return [:conformal, lowest + options[:windows] * options[:count]] if options[:strategy] == :conformal

    SMOOTH_MODELS.include?(model) ? [:gaussian, lowest + 1] : [:compound, lowest]
  end

  def history_failure(values, options, keyed)
    size = values.size
    if keyed && size < 2
      return [:keyed, "a keyed series needs at least two keys to determine its frequency, got #{size}"]
    end

    model = options[:model]
    lowest = model_minimum(model, options)
    return [model || :automatic, model_message(model, lowest, size)] if size < lowest

    kind, needed = strategy_minimum(model || selected(values), options)
    [kind, "#{kind} quantiles need at least #{needed} observations, got #{size}"] if size < needed
  end

  def model_message(model, required, size)
    case model
    when nil then "automatic model selection requires at least #{required} observations, got #{size}"
    when :seasonal_naive
      "SeasonalNaive requires at least #{required} observations (its season_length), got #{size}"
    else "#{CLASS_NAMES.fetch(model)} requires at least #{required} observations, got #{size}"
    end
  end

  def selected(values)
    Oracles.classification(values)[:demand_class] == :smooth ? :ses : :croston_sba
  end

  def history(random, size, sparse)
    values = Array.new(size) { sparse ? [0, 0.0, -0.0, Rational(0)].sample(random: random) : demand(random) }
    return values unless sparse

    (0...size).to_a.sample([size / 3, 1].max, random: random).each { |index| values[index] = demand(random) }
    values
  end

  def demand(random)
    case random.rand(3)
    when 0 then random.rand(5..10)
    when 1 then random.rand(5.0..10.0)
    else Rational(random.rand(60..120), 12)
    end
  end

  def keyed_input(random, values)
    Generators.forecast_keys(random, values.size).zip(values).shuffle(random: random).to_h
  end
end
