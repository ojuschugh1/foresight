# frozen_string_literal: true

require "test_helper"
require "foresight"

class DeterminismTest < Minitest::Test
  SEED = 58_207_913
  LIB = File.join(File.dirname(__dir__), "lib")
  MODELS = [nil, *Generators::INTERMITTENT_NAMES].freeze
  SERIES = [0, 0, 4, 0, 1, 0, 0, 7.5, 0, 2, 0, 0, 3, 0, 0, 5].freeze

  def test_an_omitted_nil_or_default_seed_gives_identical_outputs
    seen = []
    each_seed(100) do |seed, random|
      points, about = entry_points(random)
      points.except(:classify).each do |name, point|
        message = "#{name} seed #{seed}: #{about}"
        omitted = point.call
        [nil, Foresight::DEFAULT_SEED].each do |value|
          supplied = point.call(seed: value)

          assert_equal omitted, supplied, "#{message} seed: #{value.inspect}"
          assert_equal Marshal.dump(omitted), Marshal.dump(supplied), "#{message} seed: #{value.inspect}"
        end
        seen << name unless Marshal.dump(point.call(seed: 1)) == Marshal.dump(omitted)
      end
    end
    assert_equal %i[backtest evaluate forecast], seen.uniq.sort, "seed #{SEED}"
  end

  def test_a_repeated_call_ignores_the_global_generator_other_calls_and_other_threads
    each_seed(100) do |seed, random|
      points, about = entry_points(random)
      extra = random.rand < 0.5 ? { seed: random.rand(2**31) } : {}
      points.each do |name, point|
        message = "#{name} seed #{seed}: #{about} #{safe_inspect(extra)}"
        first = Marshal.dump(point.call(**extra))
        draws = random.rand(1..500)
        srand(draws)

        assert_equal first, Marshal.dump(point.call(**extra)), "#{message} after srand(#{draws})"
        draws.times { rand }

        assert_equal first, Marshal.dump(point.call(**extra)), "#{message} after #{draws} global draws"
        points.each_value { |other| other.call(seed: random.rand(2**31)) }

        assert_equal first, Marshal.dump(point.call(**extra)), "#{message} after the other calls"
        threads = Array.new(4) { Thread.new { Marshal.dump(point.call(**extra)) } }

        assert_equal [first] * 4, threads.map(&:value), "#{message} in four threads"
      end
    end
  end

  def test_two_separate_processes_and_this_one_dump_the_same_results
    script = <<~RUBY
      require "foresight"
      series = #{SERIES.inspect}
      print Marshal.dump([Foresight.forecast(series, paths: 200),
                          Foresight.forecast(series, model: :tsb, seed: 12_345, paths: 200)]).unpack1("H*")
    RUBY
    dumps = Array.new(2) do
      output, error, status = run_ruby("-I", LIB, "-e", script)

      assert status.success?, error
      output
    end
    local = [Foresight.forecast(SERIES, paths: 200), Foresight.forecast(SERIES, model: :tsb, seed: 12_345, paths: 200)]

    assert_equal dumps.first, dumps.last, safe_inspect(SERIES)
    assert_equal Marshal.dump(local).unpack1("H*"), dumps.first, safe_inspect(SERIES)
  end

  def test_no_call_moves_the_next_global_draw
    each_seed(100) do |seed, random|
      points, about = entry_points(random)
      values = intermittent(random)
      extra = random.rand < 0.5 ? { seed: random.rand(2**31) } : {}
      points.each do |name, point|
        unmoved(random, "#{name} seed #{seed}: #{about} #{safe_inspect(extra)}") { point.call(**extra) }
      end
      failing_calls(values).each do |name, call|
        message = "#{name} seed #{seed}: #{safe_inspect(values)}"
        unmoved(random, message) { assert_raises(Foresight::InputError, message) { call.call } }
      end
    end
  end

  def test_loading_the_library_leaves_the_next_global_draw_alone
    script = 'srand(7); a = rand; srand(7); require "foresight"; b = rand; puts a, b'
    output, error, status = run_ruby("-I", LIB, "-e", script)

    assert status.success?, error
    assert_equal [Random.new(7).rand.to_s] * 2, output.split
  end

  private

  def unmoved(random, message)
    state = random.rand(2**32)
    srand(state)
    expected = rand
    srand(state)
    yield

    assert_equal expected, rand, message
  end

  def failing_calls(values)
    {
      forecast_option: -> { Foresight.forecast(values, paths: 0) },
      forecast_series: -> { Foresight.forecast([*values, -1]) },
      classify_series: -> { Foresight.classify(Array.new(values.size, 0)) },
      backtest_option: -> { Foresight.backtest(values, horizon: 0, origins: 1) },
      backtest_series: -> { Foresight.backtest(values.first(3), horizon: 2, origins: 2) },
      evaluate_option: -> { Foresight.evaluate([values], horizon: 2, origins: 2, strategy: :unknown) },
      evaluate_series: -> { Foresight.evaluate([values, [*values, Float::NAN]], horizon: 2, origins: 2) }
    }
  end

  def each_seed(count)
    rng = Random.new(SEED)
    count.times do
      seed = rng.rand(2**32)
      yield seed, Random.new(seed)
    end
  end

  def entry_points(random)
    series = random_series(random)
    other = random_series(random)
    options = { model: MODELS.sample(random: random), paths: 200 }
    count = random.rand(1..4)
    window = { horizon: random.rand(1..3), origins: random.rand(1..3) }
    points = {
      forecast: ->(extra = {}) { Foresight.forecast(series, count: count, **options, **extra) },
      classify: ->(_extra = {}) { Foresight.classify(series) },
      backtest: ->(extra = {}) { Foresight.backtest(series, **window, **options, **extra) },
      evaluate: ->(extra = {}) { Foresight.evaluate([series, other], **window, **options, **extra) }
    }
    [points, "#{safe_inspect(series)} #{safe_inspect(other)} #{safe_inspect(options)} count #{count} " \
             "#{safe_inspect(window)}"]
  end

  def random_series(random)
    values = intermittent(random)
    return values if random.rand < 0.5

    Generators.forecast_keys(random, values.size).zip(values).shuffle(random: random).to_h
  end

  def intermittent(random)
    size = random.rand(12..20)
    values = Array.new(size, 0)
    (2...size).to_a.sample(random.rand(1..size / 4), random: random).each { |index| values[index] = demand(random) }
    values[random.rand(0..1)] = demand(random)
    values
  end

  def demand(random)
    random.rand < 0.5 ? random.rand(1..9) : random.rand(1.0..9.0)
  end
end
