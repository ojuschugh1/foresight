# frozen_string_literal: true

require "test_helper"
require_relative "../dev/retail/selection"

class SelectionTest < Minitest::Test
  SEED = 15_485_863
  DEMAND_CLASSES = %i[smooth erratic intermittent lumpy].freeze
  LETTERS = [*"A".."Z", *"a".."z"].freeze
  OUTCOMES = { -1 => :below_the_target, 0 => :at_the_target, 1 => :above_the_target }.freeze
  EXAMPLE = [["85123A", :smooth, 604], ["22423", :smooth, 580], ["20725", :smooth, 199], ["21212", :smooth, 200],
             ["22086", :smooth, 450], ["47566", :lumpy, 320], ["85099B", :intermittent, 150]].freeze

  def test_each_class_gets_the_target_number_of_eligible_series_or_all_of_them_with_a_shortfall
    seen = []
    each_seed(300) do |seed, random|
      candidates, settings = random_selection(random)
      about = "seed #{seed}: #{settings.inspect} #{candidates.map(&:to_a).inspect}"
      choice = Selection.choose(candidates, classes: DEMAND_CLASSES, **settings)
      minimum_length = settings[:minimum_length]
      target = settings[:target]
      eligible = DEMAND_CLASSES.to_h do |demand_class|
        [demand_class, of_class(candidates, demand_class).select { |candidate| candidate.length >= minimum_length }]
      end
      shortfalls = DEMAND_CLASSES.filter_map do |demand_class|
        included = eligible[demand_class].size
        { demand_class: demand_class, target: target, included: included } if included < target
      end

      assert_equal DEMAND_CLASSES, choice.chosen.keys, about
      assert_equal shortfalls, choice.shortfalls.map(&:to_h), about
      choice.chosen.each do |demand_class, chosen|
        pool = eligible.fetch(demand_class)
        just_short = of_class(candidates, demand_class).any? { |candidate| candidate.length == minimum_length - 1 }
        at = "#{about} #{demand_class}"

        assert_equal [target, pool.size].min, chosen.size, at
        assert_empty chosen - pool, at
        assert_equal chosen.uniq, chosen, at
        seen << OUTCOMES.fetch(pool.size <=> target)
        seen << :no_candidates if of_class(candidates, demand_class).empty?
        seen << :chosen_at_the_minimum if chosen.any? { |candidate| candidate.length == minimum_length }
        seen << :left_out_just_below_the_minimum if just_short && pool.size < target
      end
    end
    expected = %i[above_the_target at_the_target below_the_target chosen_at_the_minimum
                  left_out_just_below_the_minimum no_candidates]
    assert_equal expected, seen.uniq.sort, "seed #{SEED}"
  end

  def test_the_selection_is_the_same_for_any_input_order_and_on_every_rerun
    seen = []
    each_seed(300) do |seed, random|
      candidates, settings = random_selection(random)
      about = "seed #{seed}: #{settings.inspect} #{candidates.map(&:to_a).inspect}"
      choice = Selection.choose(candidates, classes: DEMAND_CLASSES, **settings)

      [candidates.shuffle(random: random), candidates.reverse, candidates.map(&:dup), candidates].each do |input|
        assert_equal choice, Selection.choose(input, classes: DEMAND_CLASSES, **settings), about
      end
      seen << :several_chosen if choice.chosen.values.any? { |chosen| chosen.size > 1 }
    end
    assert_equal [:several_chosen], seen.uniq, "seed #{SEED}"
  end

  def test_each_class_takes_the_eligible_codes_with_the_smallest_sha256_digests_of_seed_and_code
    candidates = EXAMPLE.map do |code, demand_class, length|
      Selection::Candidate.new(stock_code: code, demand_class: demand_class, length: length)
    end
    choices = [2026, 7].to_h do |seed|
      [seed, Selection.choose(candidates, classes: DEMAND_CLASSES, minimum_length: 200, target: 2, seed: seed)]
    end
    codes = choices.transform_values do |choice|
      choice.chosen.transform_values { |chosen| chosen.map(&:stock_code) }
    end
    shortfalls = [{ demand_class: :erratic, target: 2, included: 0 },
                  { demand_class: :intermittent, target: 2, included: 0 },
                  { demand_class: :lumpy, target: 2, included: 1 }]

    assert_equal({ smooth: %w[22086 22423], erratic: [], intermittent: [], lumpy: %w[47566] }, codes[2026])
    assert_equal({ smooth: %w[22086 21212], erratic: [], intermittent: [], lumpy: %w[47566] }, codes[7])
    assert_equal shortfalls, choices[2026].shortfalls.map(&:to_h)
  end

  private

  def each_seed(count)
    rng = Random.new(SEED)
    count.times do
      seed = rng.rand(2**32)
      yield seed, Random.new(seed)
    end
  end

  def random_selection(random)
    target = random.rand(1..8)
    minimum_length = random.rand(1..300)
    classes = DEMAND_CLASSES.flat_map { |demand_class| Array.new(random.rand(0..(2 * target + 2)), demand_class) }
    candidates = classes.zip(random_codes(random, classes.size)).map do |demand_class, code|
      Selection::Candidate.new(stock_code: code, demand_class: demand_class,
                               length: random_length(random, minimum_length))
    end
    settings = { minimum_length: minimum_length, target: target, seed: selection_seed(random) }
    [candidates.shuffle(random: random), settings]
  end

  def random_length(random, minimum_length)
    case random.rand(4)
    when 0 then minimum_length
    when 1 then [minimum_length - 1, 1].max
    else random.rand(1..(2 * minimum_length))
    end
  end

  def random_codes(random, count)
    codes = []
    codes |= [product_code(random)] while codes.size < count
    codes
  end

  def product_code(random)
    format("%05d", random.rand(100_000)) + Array.new(random.rand(0..2)) { LETTERS.sample(random: random) }.join
  end

  def selection_seed(random)
    case random.rand(4)
    when 0 then 2026
    when 1 then 0
    else random.rand(2**64)
    end
  end

  def of_class(candidates, demand_class)
    candidates.select { |candidate| candidate.demand_class == demand_class }
  end
end
