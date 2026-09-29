# frozen_string_literal: true

require "test_helper"
require "json"

class RealSubsetSchemaTest < Minitest::Test
  ROOT = File.dirname(__dir__)
  SUBSET_FILE = File.join(ROOT, "data", "online_retail_ii_subset.json")
  DOCUMENT_KEYS = %w[attribution calendar selection series source].freeze
  SERIES_KEYS = %w[demand_class start stock_code values].freeze
  ATTRIBUTION_KEYS = %w[citation creator doi license license_url modifications title].freeze
  SOURCE_KEYS = %w[uncounted_copies url worksheets xlsx_sha256 zip_sha256].freeze
  WORKSHEET_KEYS = %w[first_date last_date lines name].freeze
  SELECTION_KEYS = %w[minimum_length product_code_pattern seed shortfalls target_per_class].freeze
  SHORTFALL_KEYS = %w[demand_class included target].freeze
  DEMAND_CLASSES = %w[smooth erratic intermittent lumpy].freeze
  DIGEST = /\A[0-9a-f]{64}\z/

  def test_the_document_holds_exactly_the_attribution_the_source_the_selection_the_calendar_and_the_series
    document = subset

    assert_equal DOCUMENT_KEYS, document.keys.sort
    assert_instance_of Array, document["calendar"]
    assert_instance_of Array, document["series"]
    refute_empty document["calendar"]
    refute_empty document["series"]
  end

  def test_every_series_entry_has_exactly_a_stock_code_a_demand_class_a_start_and_values
    series.each_with_index do |entry, index|
      assert_equal SERIES_KEYS, entry.keys.sort, "series #{index}"
      assert_instance_of Array, entry["values"], "series #{index}"
    end
  end

  def test_calendar_dates_start_dates_and_worksheet_dates_are_iso_dates
    document = subset
    worksheets = document["source"]["worksheets"]
    dates = document["calendar"] + document["series"].map { |entry| entry["start"] } +
            worksheets.flat_map { |worksheet| worksheet.values_at("first_date", "last_date") }

    refute_empty dates
    dates.each { |date| assert iso_date?(date), "#{date.inspect} is not an ISO date" }
  end

  def test_stock_codes_are_strings
    series.each_with_index do |entry, index|
      assert_instance_of String, entry["stock_code"], "series #{index}"
    end
  end

  def test_demand_classes_are_one_of_the_four
    series.each do |entry|
      assert_includes DEMAND_CLASSES, entry["demand_class"], entry["stock_code"]
    end
  end

  def test_values_are_non_negative_integers
    offenders = series.flat_map do |entry|
      entry["values"].each_with_index.reject { |value, _| Integer === value && value >= 0 }.map do |value, index|
        "#{entry["stock_code"]} position #{index}: #{value.inspect}"
      end
    end

    assert_empty offenders
  end

  def test_the_attribution_holds_only_its_provenance_fields
    attribution = subset["attribution"]

    assert_equal ATTRIBUTION_KEYS, attribution.keys.sort
    (ATTRIBUTION_KEYS - ["modifications"]).each { |key| assert_instance_of String, attribution[key], key }
    assert_instance_of Array, attribution["modifications"]
    attribution["modifications"].each { |modification| assert_instance_of String, modification }
  end

  def test_the_source_holds_only_the_url_the_checksums_the_worksheet_report_and_the_copy_count
    source = subset["source"]

    assert_equal SOURCE_KEYS, source.keys.sort
    assert_instance_of String, source["url"]
    assert_match DIGEST, source["zip_sha256"]
    assert_match DIGEST, source["xlsx_sha256"]
    assert_count source["uncounted_copies"], "uncounted_copies"
    assert_instance_of Array, source["worksheets"]
    refute_empty source["worksheets"]
    source["worksheets"].each do |worksheet|
      assert_equal WORKSHEET_KEYS, worksheet.keys.sort, worksheet.inspect
      assert_instance_of String, worksheet["name"], worksheet.inspect
      assert_count worksheet["lines"], worksheet.inspect
    end
  end

  def test_the_selection_holds_only_the_seed_the_lengths_the_pattern_and_the_shortfalls
    selection = subset["selection"]

    assert_equal SELECTION_KEYS, selection.keys.sort
    %w[seed minimum_length target_per_class].each { |key| assert_count selection[key], key }
    assert_instance_of String, selection["product_code_pattern"]
    assert_instance_of Array, selection["shortfalls"]
    selection["shortfalls"].each do |shortfall|
      assert_equal SHORTFALL_KEYS, shortfall.keys.sort, shortfall.inspect
      assert_includes DEMAND_CLASSES, shortfall["demand_class"], shortfall.inspect
      assert_count shortfall["target"], shortfall.inspect
      assert_count shortfall["included"], shortfall.inspect
    end
  end

  private

  def subset
    JSON.parse(File.read(SUBSET_FILE, encoding: Encoding::UTF_8))
  rescue JSON::ParserError => e
    flunk "#{SUBSET_FILE} does not parse: #{e.message}"
  end

  def series
    subset.fetch("series")
  end

  def iso_date?(text)
    String === text && Date.iso8601(text).iso8601 == text
  rescue Date::Error
    false
  end

  def assert_count(value, message)
    assert_instance_of Integer, value, message
    assert_operator value, :>=, 0, message
  end
end
