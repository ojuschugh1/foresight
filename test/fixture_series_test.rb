# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require "foresight"

class FixtureSeriesTest < Minitest::Test
  ROOT = File.dirname(__dir__)
  FIXTURE_FILE = File.join(ROOT, "data", "fixture_series.json")
  FIELDS = %w[name provenance season_length values].freeze

  def test_the_file_holds_only_a_list_of_fixtures
    document = parse_fixture_file

    assert_equal ["fixtures"], document.keys
    assert_instance_of Array, document["fixtures"]
    refute_empty document["fixtures"]
  end

  def test_every_fixture_has_exactly_a_name_a_season_length_a_provenance_and_values
    fixtures.each_with_index do |fixture, index|
      assert_equal FIELDS, fixture.keys.sort, "fixture #{index}"
    end
  end

  def test_fixture_names_are_unique_snake_case_words
    names = fixtures.map { |fixture| fixture["name"] }

    names.each { |name| assert_match(/\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/, name) }
    assert_equal names.uniq, names
  end

  def test_season_lengths_run_from_1_to_7_and_every_series_has_24_to_60_values
    fixtures.each do |fixture|
      name = fixture["name"]

      assert_instance_of Integer, fixture["season_length"], name
      assert_includes 1..7, fixture["season_length"], name
      assert_includes 24..60, fixture["values"].size, name
    end
  end

  def test_values_are_numbers_from_0_to_100_with_at_most_two_decimals
    fixtures.each do |fixture|
      fixture["values"].each_with_index do |value, index|
        about = "#{fixture["name"]} position #{index}: #{value.inspect}"

        assert_includes [Integer, Float], value.class, about
        assert_includes 0..100, value, about
        assert_equal 1, (Rational(value.to_s) * 100).denominator, about
      end
    end
  end

  def test_every_fixture_records_whether_it_was_written_by_hand_or_generated_from_a_seed
    fixtures.each do |fixture|
      name = fixture["name"]
      provenance = fixture["provenance"]
      if provenance["kind"] == "seeded"
        assert_instance_of Integer, provenance["seed"], name
        assert_equal({ "kind" => "seeded", "seed" => provenance["seed"], "generator" => "dev/fixtures.rb #{name}" },
                     provenance, name)
      else
        assert_equal({ "kind" => "hand" }, provenance, name)
      end
    end
  end

  def test_every_demand_class_occurs_among_the_fixtures
    classes = fixtures.reject { |fixture| fixture["values"].all?(&:zero?) }.to_h do |fixture|
      [fixture["name"], Foresight.classify(fixture["values"]).demand_class]
    end

    assert_equal %i[erratic intermittent lumpy smooth], classes.values.uniq.sort, classes.inspect
  end

  def test_the_fixtures_include_every_required_shape
    shapes = fixtures.map { |fixture| [fixture["values"], fixture["season_length"]] }
    weekly = shapes.any? do |values, season_length|
      last_week = values.last(7)
      season_length == 7 && values.size >= 14 && last_week.min < last_week.max
    end
    constant = shapes.any? { |values, _| values.min.positive? && values.min == values.max }

    assert shapes.any? { |values, _| values.first.zero? }, "no series starts with a zero"
    assert shapes.any? { |values, _| values.last(2).all?(&:zero?) }, "no series ends with two zeros"
    assert weekly, "no series of season length 7 has two full cycles and a last cycle of unequal values"
    assert shapes.any? { |values, _| values.all?(&:zero?) }, "no series is all zeros"
    assert constant, "no series is a positive constant"
  end

  def test_rerunning_the_generator_reproduces_the_file_byte_for_byte
    Dir.mktmpdir do |directory|
      script = File.join(directory, "dev", "fixtures.rb")
      output = File.join(directory, "data", "fixture_series.json")
      FileUtils.mkdir_p([File.dirname(script), File.dirname(output)])
      FileUtils.cp(File.join(ROOT, "dev", "fixtures.rb"), script)
      _, error, status = run_ruby(script)

      assert status.success?, error
      assert_equal File.binread(FIXTURE_FILE), File.binread(output)
    end
  end

  private

  def parse_fixture_file
    JSON.parse(File.read(FIXTURE_FILE))
  rescue JSON::ParserError => e
    flunk "#{FIXTURE_FILE} does not parse: #{e.message}"
  end

  def fixtures
    parse_fixture_file.fetch("fixtures")
  end
end
