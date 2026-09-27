# frozen_string_literal: true

require "test_helper"
require "foresight"

class SelectorTest < Minitest::Test
  SEED = 86_028_121
  BOUND = Rational(5, 1000) + Rational(1, 10**9)
  DEMAND_CLASSES = %i[smooth erratic intermittent lumpy].freeze
  SMOOTH = %i[naive seasonal_naive ses].freeze
  INTERMITTENT = %i[croston_classic croston_sba tsb].freeze
  REASON = /\Aauto-selected (\w+) for (\w+) demand \(ADI (\d+\.\d\d), CV squared (\d+\.\d\d)\)\z/
  CLASSIFICATIONS = [
    Foresight::Classification.new(demand_class: :smooth, adi: 1.0, cv_squared: 0.0),
    Foresight::Classification.new(demand_class: :erratic, adi: 1.25, cv_squared: 2.5),
    Foresight::Classification.new(demand_class: :intermittent, adi: 3.21, cv_squared: 0.3),
    Foresight::Classification.new(demand_class: :lumpy, adi: 4.5, cv_squared: 1.2)
  ].freeze

  def test_the_rule_assigns_one_model_other_than_seasonal_naive_to_each_class
    rule = Foresight::Selector::RULE

    assert_equal({ smooth: :ses, erratic: :croston_sba, intermittent: :croston_sba, lumpy: :croston_sba }, rule)
    assert_predicate rule, :frozen?
    assert_equal DEMAND_CLASSES.sort, rule.keys.sort
    rule.each do |demand_class, model|
      assert_includes Foresight::MODELS.keys, model, demand_class.inspect
      refute_equal :seasonal_naive, model, demand_class.inspect
    end
  end

  def test_smooth_demand_gets_a_smooth_model_and_intermittent_and_lumpy_demand_an_intermittent_model
    rule = Foresight::Selector::RULE

    assert_includes SMOOTH, rule.fetch(:smooth)
    assert_includes INTERMITTENT, rule.fetch(:intermittent)
    assert_includes INTERMITTENT, rule.fetch(:lumpy)
  end

  def test_model_for_follows_the_rule_for_a_classification_of_each_class
    CLASSIFICATIONS.each do |classification|
      assert_equal Foresight::Selector::RULE.fetch(classification.demand_class),
                   Foresight::Selector.model_for(classification), classification.inspect
    end
  end

  def test_automatic_selection_needs_at_least_one_observation
    assert_equal 1, Foresight::Selector::MINIMUM_HISTORY
  end

  def test_the_automatic_reason_names_the_class_the_model_and_both_values
    classification = Foresight::Classification.new(demand_class: :intermittent, adi: 3.21, cv_squared: 0.3)

    assert_equal "auto-selected croston_sba for intermittent demand (ADI 3.21, CV squared 0.30)",
                 Foresight::Selector.reason(classification, nil)
  end

  def test_a_specified_model_is_named_as_the_callers_choice_with_or_without_a_classification
    intermittent = Foresight::Classification.new(demand_class: :intermittent, adi: 3.21, cv_squared: 0.3)

    assert_equal "croston_sba was specified by the caller", Foresight::Selector.reason(intermittent, :croston_sba)
    assert_equal "croston_sba was specified by the caller", Foresight::Selector.reason(nil, :croston_sba)
    Foresight::MODELS.each_key do |model|
      [nil, *CLASSIFICATIONS].each do |classification|
        assert_equal "#{model} was specified by the caller", Foresight::Selector.reason(classification, model),
                     "#{model}, #{classification.inspect}"
      end
    end
  end

  def test_the_automatic_reason_rounds_both_values_to_two_decimals
    classes = []
    seen = []
    each_seed(1_000) do |seed, random|
      classification = Foresight::Classification.new(demand_class: DEMAND_CLASSES.sample(random: random),
                                                      adi: adi(random), cv_squared: cv_squared(random))

      assert_reason classification, "seed #{seed}: #{classification.inspect}"
      classes << classification.demand_class
      seen.concat(kinds(classification.adi), kinds(classification.cv_squared))
    end
    assert_equal DEMAND_CLASSES.sort, classes.uniq.sort, "seed #{SEED}"
    assert_equal %i[large near_tie tie tiny whole], seen.uniq.sort, "seed #{SEED}"
  end

  def test_the_automatic_reason_states_the_classification_of_random_series
    classes = []
    each_seed(200) do |seed, random|
      input = demanded { random.rand < 0.3 ? Generators.numbers(random) : Generators.keyed(random).input }
      about = "seed #{seed}: #{safe_inspect(input)}"
      classification = classified(input, about)

      assert_reason classification, about
      classes << classification.demand_class
    end
    assert_equal DEMAND_CLASSES.sort, classes.uniq.sort, "seed #{SEED}"
  end

  private

  def each_seed(count)
    rng = Random.new(SEED)
    count.times do
      seed = rng.rand(2**32)
      yield seed, Random.new(seed)
    end
  end

  def adi(random)
    case random.rand(8)
    when 0 then 1.0
    when 1 then 1 + 10.0**random.rand(-15.0..-3.0)
    when 2, 3, 4 then halfway(random, 1)
    else 10.0**random.rand(0.0..12.0)
    end
  end

  def cv_squared(random)
    case random.rand(8)
    when 0 then 0.0
    when 1 then 10.0**random.rand(-320.0..-3.0)
    when 2, 3, 4 then halfway(random, 0)
    else 10.0**random.rand(-3.0..12.0)
    end
  end

  def halfway(random, minimum)
    hundredths = random.rand(100 * minimum..10**random.rand(3..11))
    Rational(2 * hundredths + 1, 200).to_f
  end

  def kinds(value)
    exact = value.to_r
    distance = (exact - ((exact * 100).floor + 0.5r) / 100).abs
    {
      tie: distance.zero?,
      near_tie: distance.positive? && distance <= value.next_float - value,
      whole: exact.denominator == 1,
      tiny: value.positive? && value < 1e-6,
      large: value >= 1e7
    }.select { |_, found| found }.keys
  end

  def demanded
    loop do
      input = yield
      return input if (Hash === input ? input.values : input).any? { |value| value != 0 }
    end
  end

  def classified(input, about)
    Foresight.classify(input)
  rescue Foresight::InputError => e
    flunk "#{about}: #{e.message}"
  end

  def assert_reason(classification, about)
    reason = Foresight::Selector.reason(classification, nil)
    match = REASON.match(reason)

    refute_nil match, "#{about}: #{reason.inspect}"
    model, demand_class, *values = match.captures
    expected = [Foresight::Selector::RULE.fetch(classification.demand_class), classification.demand_class]
    assert_equal expected.map(&:to_s), [model, demand_class], about
    values.zip([classification.adi, classification.cv_squared]).each do |text, value|
      difference = (Rational(text) - value.to_r).abs

      assert_operator difference, :<=, BOUND, "#{about}: #{reason.inspect}"
    end
  end
end
