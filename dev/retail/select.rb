# frozen_string_literal: true

require "fileutils"
require "json"
require "foresight"
require_relative "selection"

ROOT = File.expand_path("../..", __dir__)
INTERMEDIATE_FILE = File.join(ROOT, "tmp", "retail_intermediate.json")
CONFIG_FILE = File.join(ROOT, "validation", "study_config.json")
SUBSET_FILE = File.join(ROOT, "data", "online_retail_ii_subset.json")
TEMPORARY_FILE = "#{SUBSET_FILE}.tmp"
URL = "https://archive.ics.uci.edu/static/public/502/online+retail+ii.zip"
PRODUCT_CODE = /\A[0-9]{5}[A-Za-z]*\z/
SEED = 2026
MINIMUM_LENGTH = 200
TARGET = 25
STRATEGIES = %i[distribution conformal].freeze
BACKTEST_SETTINGS = %w[horizon origins step windows].freeze
WORKSHEET_FIELDS = %w[name first_date last_date lines].freeze
ATTRIBUTION = {
  "title" => "Online Retail II",
  "creator" => "Daqing Chen",
  "citation" => "Chen, D. (2012). Online Retail II [Dataset]. UCI Machine Learning Repository. " \
                "https://doi.org/10.24432/C5CG6D",
  "doi" => "10.24432/C5CG6D",
  "license" => "CC BY 4.0",
  "license_url" => "https://creativecommons.org/licenses/by/4.0/",
  "modifications" => [
    "lines copied across the two worksheets are counted once; repeated identical lines within one worksheet are kept",
    "cancellation lines, lines with a quantity of zero or less, and lines whose stock code is not a product code " \
    "are dropped",
    "quantities are summed per stock code and trading date over the trading calendar, " \
    "the dates with at least one transaction",
    "each series starts at its first trading date with positive demand",
    "the subset is a deterministic selection described in docs/validation.md"
  ]
}.freeze

def attempt(step)
  yield
rescue StandardError => e
  abort "#{step} failed: #{e.message}"
end

def check_minimum_length
  config = JSON.parse(File.read(CONFIG_FILE))
  settings = BACKTEST_SETTINGS.to_h { |name| [name.to_sym, config.fetch(name)] }
  STRATEGIES.each do |strategy|
    Foresight.backtest(Array.new(MINIMUM_LENGTH, 1), strategy: strategy, **settings)
  rescue Foresight::InputError => e
    raise "#{strategy} quantiles: #{e.message}"
  end
end

def read_intermediate
  intermediate = JSON.parse(File.read(INTERMEDIATE_FILE))
  calendar = intermediate.fetch("calendar")
  ascending = calendar.each_cons(2).all? { |earlier, later| earlier < later }
  raise "the calendar is not in ascending order" unless ascending

  [calendar, intermediate.fetch("daily_sums"), source_block(intermediate.fetch("source"))]
end

def source_block(source)
  worksheets = source.fetch("worksheets").map do |worksheet|
    WORKSHEET_FIELDS.to_h { |field| [field, worksheet.fetch(field)] }
  end
  {
    "url" => URL,
    "zip_sha256" => source.fetch("zip_sha256"),
    "xlsx_sha256" => source.fetch("xlsx_sha256"),
    "worksheets" => worksheets.sort_by { |worksheet| worksheet.fetch("name") },
    "uncounted_copies" => source.fetch("uncounted_copies")
  }
end

def build_series(calendar, daily_sums)
  positions = calendar.each_with_index.to_h
  daily_sums.to_h do |code, sums|
    check_daily_sums(code, sums, positions)
    start = sums.keys.map { |date| positions.fetch(date) }.min
    [code, { "start" => calendar[start], "values" => calendar.drop(start).map { |date| sums.fetch(date, 0) } }]
  end
end

def check_daily_sums(code, sums, positions)
  raise "stock code #{code} does not match #{PRODUCT_CODE.source}" unless PRODUCT_CODE.match?(code)

  sums.each do |date, quantity|
    raise "stock code #{code} has demand on #{date}, which is not a trading date" unless positions.key?(date)
    next if Integer === quantity && quantity.positive?

    raise "stock code #{code} has demand #{quantity.inspect} on #{date}, which is not a positive Integer"
  end
end

def subset(calendar, source, series, choice)
  chosen = choice.chosen.values.flatten(1).sort_by(&:stock_code)
  {
    "attribution" => ATTRIBUTION,
    "source" => source,
    "selection" => {
      "seed" => SEED,
      "minimum_length" => MINIMUM_LENGTH,
      "target_per_class" => TARGET,
      "product_code_pattern" => PRODUCT_CODE.source,
      "shortfalls" => choice.shortfalls.map { |shortfall| shortfall_entry(shortfall) }
    },
    "calendar" => calendar,
    "series" => chosen.map { |candidate| series_entry(candidate, series.fetch(candidate.stock_code)) }
  }
end

def shortfall_entry(shortfall)
  { "demand_class" => shortfall.demand_class.to_s, "target" => shortfall.target, "included" => shortfall.included }
end

def series_entry(candidate, entry)
  { "stock_code" => candidate.stock_code, "demand_class" => candidate.demand_class.to_s,
    "start" => entry.fetch("start"), "values" => entry.fetch("values") }
end

def write_subset(document)
  File.write(TEMPORARY_FILE, "#{JSON.pretty_generate(document)}\n")
  File.rename(TEMPORARY_FILE, SUBSET_FILE)
ensure
  FileUtils.rm_f(TEMPORARY_FILE)
end

attempt("checking the minimum length") { check_minimum_length }
calendar, daily_sums, source = attempt("reading the intermediate file") { read_intermediate }
series = attempt("building the series") { build_series(calendar, daily_sums) }
demand_classes = attempt("classifying the series") do
  series.transform_values { |entry| Foresight.classify(entry.fetch("values")).demand_class }
end
choice = attempt("selecting the series") do
  candidates = series.map do |code, entry|
    Selection::Candidate.new(stock_code: code, demand_class: demand_classes.fetch(code),
                             length: entry.fetch("values").size)
  end
  Selection.choose(candidates, classes: Foresight::EvaluationReport::DEMAND_CLASSES,
                               minimum_length: MINIMUM_LENGTH, target: TARGET, seed: SEED)
end
attempt("writing the subset") { write_subset(subset(calendar, source, series, choice)) }
choice.shortfalls.each do |shortfall|
  puts "#{shortfall.demand_class}: #{shortfall.included} eligible series, below the target of #{shortfall.target}"
end
