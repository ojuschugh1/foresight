# frozen_string_literal: true

require "test_helper"
require "oracles"
require "foresight"

class BacktesterTest < Minitest::Test
  SEED = 48_205_913
  TOLERANCE = 1e-12
  SLACK = 1e-300
  METRICS = %i[mase_scale mae rmse mase].freeze
  PARTS = %i[scaled_pinball scaled_pinball_zero scaled_pinball_nonzero].freeze
  LEVEL_COUNTS = %i[covered coverage lead_time_hit].freeze
  WINDOW_NAMES = %i[horizon origins step].freeze
  MODEL_LABELS = %i[automatic naive seasonal_naive ses croston_classic croston_sba tsb].freeze

  def test_each_origin_is_a_forecast_of_its_prefix_scored_on_the_held_out_window
    seen = []
    each_seed(120) do |seed, random|
      model = [nil, *Generators::MODEL_NAMES].sample(random: random)
      options = Generators.backtest_options(random, model, Generators::STRATEGY_NAMES.sample(random: random))
      settings = Oracles.backtest_settings(options)
      size = Oracles.backtest_length(settings) + extra_length(random)
      values = Generators.backtest_values(random, size, settings[:horizon], mixed: random.rand < 0.5)
      call = Generators.backtest_call(random, options, values, keyed: random.rand < 0.5)
      about = "seed #{seed}: #{safe_inspect(call.input)} #{safe_inspect(options)}"
      backtest = Foresight.backtest(call.input, **options)
      positions = Oracles.origin_positions(size, settings)
      kept = positions.reject { |position| model.nil? && values.first(position).all?(&:zero?) }
      starts = kept.map { |position| call.keys ? call.keys[position] : position }
      assert_equal typed(starts), typed(backtest.origins.map(&:start)), about
      assert_equal typed([positions.size - kept.size]), typed([backtest.excluded_origins]), about
      kept.zip(backtest.origins).each do |position, origin|
        assert_origin values, position, settings, options, origin, about
        seen << :zero_scale if origin.mase_scale.zero?
      end
      seen << (call.keys ? :keyed : :array) << settings[:strategy] << (model || :automatic)
      seen << :excluded if kept.size < positions.size
    end
    expected = MODEL_LABELS + Generators::STRATEGY_NAMES + %i[keyed array excluded zero_scale]
    assert_equal expected.sort, seen.uniq.sort, "seed #{SEED}"
  end

  def test_metrics_agree_with_exact_arithmetic_on_their_float_arguments
    each_seed(300) do |seed, random|
      size = random.rand(1..12)
      actual = Array.new(size) { Generators.metric_float(random) }
      forecast = Array.new(size) { Generators.metric_float(random) }
      history = Array.new(random.rand(2..40)) { Generators.metric_float(random) }
      level = Generators.option_value(random, :levels).sample(random: random)
      about = "seed #{seed}: #{safe_inspect([actual, forecast, history, level])}"
      assert_metric Oracles.mase_scale(history), Foresight::Metrics.scale(history), about
      assert_metric Oracles.mean_absolute_error(actual, forecast), Foresight::Metrics.mae(actual, forecast), about
      assert_metric Math.sqrt(Oracles.mean_squared_error(actual, forecast)).to_r,
                    Foresight::Metrics.rmse(actual, forecast), about
      actual.zip(forecast).each do |value, quantile|
        assert_metric Oracles.pinball(level, quantile, value), Foresight::Metrics.pinball(level, quantile, value), about
      end
    end
  end

  def test_the_length_check_follows_the_series_checks_and_is_met_exactly_at_the_backtest_length
    seen = []
    each_seed(120) do |seed, random|
      model = [nil, *Generators::MODEL_NAMES].sample(random: random)
      options = Generators.backtest_options(random, model, Generators::STRATEGY_NAMES.sample(random: random))
      settings = Oracles.backtest_settings(options)
      length = Oracles.backtest_length(settings)
      keyed = random.rand < 0.5
      [length - 1, length].each do |size|
        values = Generators.backtest_values(random, size, settings[:horizon], mixed: random.rand < 0.5)
        call = Generators.backtest_call(random, options, values, keyed: keyed)
        about = "seed #{seed}: #{safe_inspect(call.input)} #{safe_inspect(options)}"
        if size < length
          error = assert_raises(Foresight::InputError, about) { Foresight.backtest(call.input, **options) }
          assert_equal Oracles.length_message(settings, size), error.message, about
        else
          backtest = Foresight.backtest(call.input, **options)
          assert_equal settings[:origins], backtest.origins.size + backtest.excluded_origins, about
        end
      end
      [[1, -2], { Date.new(2026, 1, 1) => 5 }].each do |input|
        about = "seed #{seed}: #{safe_inspect(input)} #{safe_inspect(options)}"
        error = assert_raises(Foresight::InputError, about) { Foresight.backtest(input, **options) }
        assert_equal Generators.violation(input, true).last, error.message, about
      end
      seen << (keyed ? :keyed : :array) << settings[:strategy] << (model || :automatic)
    end
    expected = MODEL_LABELS + Generators::STRATEGY_NAMES + %i[keyed array]
    assert_equal expected.sort, seen.uniq.sort, "seed #{SEED}"
  end

  def test_a_date_keyed_backtest_reports_its_keys_as_the_origin_starts
    keys = Array.new(12) { |index| Date.new(2026, 3, 1) + index }
    values = [3, 5, 4, 6, 5, 7, 6, 8, 7, 9, 8, 10]
    backtest = Foresight.backtest(keys.zip(values).reverse.to_h, horizon: 2, origins: 3, model: :naive)
    assert_equal typed(keys.values_at(6, 8, 10)), typed(backtest.origins.map(&:start))
  end

  def test_the_zero_and_nonzero_parts_split_the_pinball_loss_by_held_out_value
    only_zeros = Foresight.backtest([4, 6, 5, 7, 0, -0.0], horizon: 2, origins: 1, model: :naive).origins.first
    no_zeros = Foresight.backtest([4, 6, 5, 7, 3, 9], horizon: 2, origins: 1, model: :naive).origins.first
    assert_equal typed([2, 0, 0, 2]), typed([only_zeros.zero_held_out, only_zeros.nonzero_held_out,
                                             no_zeros.zero_held_out, no_zeros.nonzero_held_out])
    [[only_zeros, :scaled_pinball_zero, :scaled_pinball_nonzero],
     [no_zeros, :scaled_pinball_nonzero, :scaled_pinball_zero]].each do |origin, full, empty|
      origin.scaled_pinball.each do |level, whole|
        assert_operator whole, :>, 0, level
        assert_equal whole, origin[full][level], level
        assert_equal typed([0.0]), typed([origin[empty][level]]), level
      end
    end
  end

  def test_a_backtest_whose_origins_are_all_excluded_has_no_means_and_no_coverage
    backtest = Foresight.backtest([0, 0.0, -0.0, Rational(0)] * 3 + [0, 4], horizon: 2, origins: 3, step: 2)
    levels = Oracles::OPTION_DEFAULTS[:levels]
    assert_empty backtest.origins
    assert_equal typed([3, 0, 0, 0, 0]), typed([backtest.excluded_origins, backtest.zero_scale_origins,
                                                backtest.held_out, backtest.zero_held_out, backtest.nonzero_held_out])
    assert_nil backtest.mae
    assert_nil backtest.rmse
    assert_nil backtest.mase
    %i[scaled_pinball scaled_pinball_zero scaled_pinball_nonzero coverage lead_time_coverage].each do |name|
      assert_equal levels.to_h { |level| [level, nil] }, backtest[name], name
    end
    %i[covered lead_time_hits].each do |name|
      assert_equal typed_pairs(levels.to_h { |level| [level, 0] }), typed_pairs(backtest[name]), name
    end
  end

  def test_each_series_summary_pools_counts_and_averages_its_origins
    seen = []
    each_seed(120) do |seed, random|
      backtest, settings, keyed, about = random_backtest(seed, random)
      origins = backtest.origins
      levels = settings[:levels]
      held_out = settings[:horizon] * origins.size
      zero_scale = origins.count { |origin| origin.mase_scale.zero? }
      assert_equal typed([settings[:origins] - origins.size, zero_scale, held_out, origins.sum(&:zero_held_out),
                          origins.sum(&:nonzero_held_out)]),
                   typed([backtest.excluded_origins, backtest.zero_scale_origins, backtest.held_out,
                          backtest.zero_held_out, backtest.nonzero_held_out]), about
      %i[mae rmse mase].each do |name|
        assert_metric Oracles.present_mean(origins.map(&name)), backtest[name], -> { "#{about} #{name}" }
      end
      PARTS.each do |name|
        assert_equal typed(levels), typed(backtest[name].keys), about
        levels.each do |level|
          assert_metric Oracles.present_mean(origins.map { |origin| origin[name][level] }), backtest[name][level],
                        -> { "#{about} #{name} #{level}" }
        end
      end
      covered = levels.to_h { |level| [level, origins.sum { |origin| origin.covered[level] }] }
      hits = levels.to_h { |level| [level, origins.count { |origin| origin.lead_time_hit[level] == true }] }
      coverage = covered.transform_values { |count| Rational(count, held_out).to_f unless held_out.zero? }
      lead_time = hits.transform_values { |count| Rational(count, origins.size).to_f unless origins.empty? }
      assert_equal typed_pairs(covered), typed_pairs(backtest.covered), about
      assert_equal typed_pairs(hits), typed_pairs(backtest.lead_time_hits), about
      assert_equal typed_pairs(coverage), typed_pairs(backtest.coverage), about
      assert_equal typed_pairs(lead_time), typed_pairs(backtest.lead_time_coverage), about
      seen << (keyed ? :keyed : :array) << settings[:strategy] << (settings[:model] || :automatic)
      seen << :excluded if backtest.excluded_origins.positive?
      seen << :zero_scale if zero_scale.positive?
      seen << :both_scales if zero_scale.between?(1, origins.size - 1)
      seen << :no_origins if origins.empty?
    end
    expected = MODEL_LABELS + Generators::STRATEGY_NAMES + %i[keyed array excluded zero_scale both_scales no_origins]
    assert_equal expected.sort, seen.uniq.sort, "seed #{SEED}"
  end

  def test_the_pinball_parts_add_up_at_every_origin_and_for_the_series
    seen = []
    each_seed(120) do |seed, random|
      backtest, settings, _, about = random_backtest(seed, random)
      origins = backtest.origins
      origins.each do |origin|
        where = "#{about} origin #{safe_inspect(origin.start)}"
        assert_equal typed([settings[:horizon]]), typed([origin.zero_held_out + origin.nonzero_held_out]), where
        settings[:levels].each do |level|
          parts = PARTS.map { |name| origin[name][level] }
          if origin.mase_scale.zero?
            assert_equal [nil, nil, nil], parts, where
          else
            assert_parts(*parts, "#{where} #{level}")
          end
        end
        seen << :zero_scale if origin.mase_scale.zero?
        seen << :mixed_window if origin.zero_held_out.positive? && origin.nonzero_held_out.positive?
      end
      settings[:levels].each do |level|
        parts = PARTS.map { |name| backtest[name][level] }
        PARTS.zip(parts).each do |name, part|
          assert_metric Oracles.present_mean(origins.map { |origin| origin[name][level] }), part,
                        -> { "#{about} #{name} #{level}" }
        end
        assert_equal [parts.first.nil?] * 3, parts.map(&:nil?), about
        assert_parts(*parts, "#{about} #{level}") unless parts.first.nil?
        seen << :nil_loss if parts.first.nil?
      end
      counts = [backtest.zero_held_out, backtest.nonzero_held_out]
      assert_equal typed([origins.sum(&:zero_held_out), origins.sum(&:nonzero_held_out), backtest.held_out]),
                   typed([*counts, counts.sum]), about
    end
    assert_equal %i[mixed_window nil_loss zero_scale], seen.uniq.sort, "seed #{SEED}"
  end

  private

  def assert_parts(whole, zero, nonzero, about)
    [whole, zero, nonzero].each do |part|
      assert_instance_of Float, part, about
      assert_operator part, :>=, 0, about
    end
    error = (zero.to_r + nonzero.to_r - whole.to_r).abs
    assert_operator error, :<=, whole.to_r * TOLERANCE, about
  end

  def random_backtest(seed, random)
    model = [nil, *Generators::MODEL_NAMES].sample(random: random)
    options = Generators.backtest_options(random, model, Generators::STRATEGY_NAMES.sample(random: random))
    settings = Oracles.backtest_settings(options)
    size = Oracles.backtest_length(settings) + extra_length(random)
    values = Generators.backtest_values(random, size, settings[:horizon], mixed: random.rand < 0.5)
    values.fill(0, size - settings[:horizon]) { Generators::ZEROS.sample(random: random) } if random.rand < 0.15
    call = Generators.backtest_call(random, options, values, keyed: random.rand < 0.5)
    about = "seed #{seed}: #{safe_inspect(call.input)} #{safe_inspect(options)}"
    [Foresight.backtest(call.input, **options), settings, !call.keys.nil?, about]
  end

  def assert_origin(values, position, settings, options, origin, about)
    horizon = settings[:horizon]
    history = values.first(position)
    result = Foresight.forecast(history, count: horizon, **options.reject { |name, _| WINDOW_NAMES.include?(name) })
    expected = Oracles.origin_metrics(history, values[position, horizon], result.forecast, result.quantiles,
                                      result.lead_time_quantiles, settings[:levels])
    about = "#{about} origin #{position}"
    assert_equal result.model, origin.model, about
    assert_instance_of Float, origin.mase_scale, about
    METRICS.each { |name| assert_metric expected[name], origin[name], -> { "#{about} #{name}" } }
    PARTS.each do |name|
      assert_equal typed(expected[name].keys), typed(origin[name].keys), about
      expected[name].each do |level, value|
        assert_metric value, origin[name][level], -> { "#{about} #{name} #{level}" }
      end
    end
    assert_equal typed([expected[:zero_held_out], expected[:nonzero_held_out]]),
                 typed([origin.zero_held_out, origin.nonzero_held_out]), about
    LEVEL_COUNTS.each { |name| assert_equal typed_pairs(expected[name]), typed_pairs(origin[name]), about }
  end

  def assert_metric(expected, actual, about)
    if expected.nil?
      assert_nil actual, about
    else
      assert_instance_of Float, actual, about
      error = (actual.to_r - expected).abs
      assert_operator error, :<=, expected.abs * TOLERANCE + SLACK, about
    end
  end

  def typed(items)
    items.map { |item| [item.class, item] }
  end

  def typed_pairs(hash)
    hash.map { |key, value| [key.class, key, value.class, value] }
  end

  def extra_length(random)
    random.rand < 0.3 ? 0 : random.rand(1..20)
  end

  def each_seed(count)
    rng = Random.new(SEED)
    count.times do
      seed = rng.rand(2**32)
      yield seed, Random.new(seed)
    end
  end
end
