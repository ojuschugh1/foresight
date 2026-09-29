# frozen_string_literal: true

require "test_helper"
require "json"
require "foresight"

class RealSubsetTest < Minitest::Test
  ROOT = File.dirname(__dir__)
  SUBSET_FILE = File.join(ROOT, "data", "online_retail_ii_subset.json")
  PRODUCT_CODE = /\A[0-9]{5}[A-Za-z]*\z/
  DOI = "10.24432/C5CG6D"
  LICENSE_URL = "https://creativecommons.org/licenses/by/4.0/"
  MODIFICATIONS = [
    /lines copied across the two worksheets are counted once/,
    /cancellation lines, lines with a quantity of zero or less, and lines whose stock code is not a product code/,
    /summed per stock code and trading date over the trading calendar/,
    /starts at its first trading date with positive demand/,
    /deterministic selection/
  ].freeze

  def test_every_stock_code_is_a_distinct_product_code
    codes = series.map { |entry| entry["stock_code"] }

    codes.each { |code| assert_match PRODUCT_CODE, code }
    assert_equal codes.uniq, codes
    assert_equal PRODUCT_CODE.source, subset["selection"]["product_code_pattern"]
  end

  def test_values_run_from_the_start_date_to_the_last_calendar_date
    calendar = subset["calendar"]

    assert_equal calendar.sort, calendar
    assert_equal calendar.uniq, calendar
    series.each do |entry|
      code = entry["stock_code"]
      position = calendar.index(entry["start"])

      refute_nil position, "#{code} starts on #{entry["start"]}, which is not a trading date"
      assert_equal calendar.size - position, entry["values"].size, code
    end
  end

  def test_each_series_starts_with_positive_demand
    series.each do |entry|
      assert_operator entry["values"].first, :>, 0, entry["stock_code"]
    end
  end

  def test_the_attribution_names_the_dataset_its_creator_the_citation_the_license_and_the_modifications
    attribution = subset["attribution"]
    modifications = attribution["modifications"]

    assert_equal "Online Retail II", attribution["title"]
    assert_equal "Daqing Chen", attribution["creator"]
    assert_equal DOI, attribution["doi"]
    assert_includes attribution["citation"], attribution["title"]
    assert_includes attribution["citation"], "https://doi.org/#{DOI}"
    assert_equal "CC BY 4.0", attribution["license"]
    assert_equal LICENSE_URL, attribution["license_url"]
    assert_equal MODIFICATIONS.size, modifications.size, modifications.inspect
    MODIFICATIONS.zip(modifications).each { |pattern, modification| assert_match pattern, modification }
  end

  def test_each_recorded_demand_class_is_the_class_the_classifier_assigns
    series.each do |entry|
      assert_equal entry["demand_class"], Foresight.classify(entry["values"]).demand_class.to_s, entry["stock_code"]
    end
  end

  def test_the_file_is_the_pretty_generated_form_of_its_content_with_a_trailing_newline
    assert_equal "#{JSON.pretty_generate(subset)}\n", text
  end

  private

  def text
    File.read(SUBSET_FILE, encoding: Encoding::UTF_8)
  end

  def subset
    JSON.parse(text)
  rescue JSON::ParserError => e
    flunk "#{SUBSET_FILE} does not parse: #{e.message}"
  end

  def series
    subset.fetch("series")
  end
end
