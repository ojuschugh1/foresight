# frozen_string_literal: true

require "fileutils"
require "json"
require "foresight"

module Render
  ROOT = File.expand_path("..", __dir__)
  FIXTURE_FILE = File.join(ROOT, "data", "fixture_series.json")
  REFERENCE_FILE = File.join(ROOT, "data", "reference_outputs.json")
  SUBSET_FILE = File.join(ROOT, "data", "online_retail_ii_subset.json")
  RESULTS_FILE = File.join(ROOT, "validation", "study_results.json")
  REQUIREMENTS_FILES = %w[dev/reference/requirements.txt dev/retail/requirements.txt].map do |path|
    File.join(ROOT, path)
  end.freeze
  DOCUMENTS = { methodology: File.join(ROOT, "docs", "methodology.md"),
                validation: File.join(ROOT, "docs", "validation.md") }.freeze
  REGIONS = %w[defaults parity fixtures processes coverage summary-synthetic summary-real configuration worse
               worksheets packages].freeze
  MARKER = %r{^<!-- (/?)generated:([a-z-]+) -->$}
  REGION = %r{^<!-- generated:([a-z-]+) -->\n(.*?)^<!-- /generated:\1 -->$}m
  REFERENCE_MODELS = { "Naive" => :naive, "SeasonalNaive" => :seasonal_naive,
                       "SimpleExponentialSmoothingOptimized" => :ses, "CrostonClassic" => :croston_classic,
                       "CrostonSBA" => :croston_sba, "TSB" => :tsb }.freeze
  SES_TOLERANCE = 1e-5
  DETERMINISTIC_TOLERANCE = 1e-9
  STRATEGIES = %w[distribution conformal].freeze
  STATISTICS = %w[coverage lead_time_coverage scaled_pinball].freeze
  DIFFERENCES = %w[coverage_error lead_time_coverage_error scaled_pinball coverage lead_time_coverage].freeze
  WORSE = { "coverage_error" => ["coverage", "further from the level by"],
            "lead_time_coverage_error" => ["lead-time coverage", "further from the level by"],
            "scaled_pinball" => ["scaled pinball loss", "larger by"] }.freeze
  COUNTS = { "series" => "Series", "origins" => "Origins", "held_out" => "Held-out observations",
             "zero_held_out" => "Zero held-out observations", "nonzero_held_out" => "Non-zero held-out observations",
             "excluded_origins" => "Excluded origins", "zero_scale_origins" => "Origins with an undefined MASE" }.freeze
  SYSTEMS = { "darwin" => "macOS", "linux" => "Linux" }.freeze
  PLACES = 3
  UNDEFINED = "undefined"

  class Error < StandardError
  end

  Comparison = Struct.new(:forecasts, :alpha, keyword_init: true)

  class << self
    def run(fixture_path: FIXTURE_FILE, reference_path: REFERENCE_FILE, subset_path: SUBSET_FILE,
            results_path: RESULTS_FILE, requirements_paths: REQUIREMENTS_FILES, document_paths: DOCUMENTS)
      regions = regions(fixture_path: fixture_path, reference_path: reference_path, subset_path: subset_path,
                        results_path: results_path, requirements_paths: requirements_paths)
      documents = document_paths.transform_values { |path| read(path) }
      filled = documents.to_h { |name, text| [name, fill_document(text, regions, document_paths.fetch(name))] }
      check_every_region_once(documents, regions.keys)
      filled.each { |name, text| write(document_paths.fetch(name), text) }
      regions
    end

    def regions(fixture_path: FIXTURE_FILE, reference_path: REFERENCE_FILE, subset_path: SUBSET_FILE,
                results_path: RESULTS_FILE, requirements_paths: REQUIREMENTS_FILES)
      fixtures = read_json(fixture_path).fetch("fixtures")
      reference = read_json(reference_path)
      subset = read_json(subset_path)
      results = read_json(results_path)
      levels = results.fetch("config").fetch("levels")
      {
        "defaults" => defaults, "parity" => parity(fixtures, reference), "fixtures" => fixture_table(fixtures),
        "processes" => processes(results), "coverage" => coverage(results),
        "summary-synthetic" => summary(results.fetch("synthetic"), levels, false),
        "summary-real" => summary(results.fetch("real"), levels, true),
        "configuration" => configuration(results), "worse" => worse(results), "worksheets" => worksheets(subset),
        "packages" => packages(requirements_paths)
      }
    end

    def fill(text, regions)
      names = region_names(text, regions.keys)
      replaced = []
      filled = text.gsub(REGION) do
        name = Regexp.last_match(1)
        replaced << name
        "<!-- generated:#{name} -->\n#{regions.fetch(name)}\n<!-- /generated:#{name} -->"
      end
      disordered = names - replaced
      raise Error, "generated region #{list(disordered)} ends before it starts" unless disordered.empty?

      filled
    end

    private

    def region_names(text, known)
      starts, finishes = text.scan(MARKER).partition { |slash, _| slash.empty? }.map { |found| found.map(&:last) }
      unknown = (starts | finishes) - known
      raise Error, "unknown generated region #{list(unknown)}" unless unknown.empty?

      repeated = (starts.tally.to_a + finishes.tally.to_a).filter_map { |name, count| name if count > 1 }.uniq
      raise Error, "generated region #{list(repeated)} is marked more than once" unless repeated.empty?

      unpaired = (starts - finishes) | (finishes - starts)
      raise Error, "generated region #{list(unpaired)} has a start or an end marker but not both" unless unpaired.empty?

      starts
    end

    def fill_document(text, regions, path)
      fill(text, regions)
    rescue Error => e
      raise Error, "#{path}: #{e.message}"
    end

    def check_every_region_once(documents, names)
      found = documents.values.flat_map do |text|
        text.scan(MARKER).filter_map { |slash, name| name if slash.empty? }
      end
      missing = names - found
      raise Error, "generated region #{list(missing)} appears in no document" unless missing.empty?

      repeated = found.tally.filter_map { |name, count| name if count > 1 }
      raise Error, "generated region #{list(repeated)} appears in more than one document" unless repeated.empty?
    end

    def defaults
      settings = Foresight::Options.forecast({})
      rows = [["sample paths (`paths`)", settings[:paths]], ["calibration windows (`windows`)", settings[:windows]],
              ["seed (`seed`)", settings[:seed]], ["TSB size smoothing parameter (`alpha_d`)", settings[:alpha_d]],
              ["TSB occurrence smoothing parameter (`alpha_p`)", settings[:alpha_p]]]
      [table(%w[Setting Default], rows.map { |name, value| [name, value.to_s] }),
       "The operations that take a seed are `Foresight.forecast`, `Foresight.backtest`, `Foresight.evaluate` and " \
       "`Foresight::Backtester.new`, all through the `seed` option."].join("\n\n")
    end

    def parity(fixtures, reference)
      horizon = reference.fetch("horizon")
      settings = Foresight::Options.forecast({})
      comparisons = fixtures.to_h do |fixture|
        [fixture["name"], comparison(fixture, reference.fetch("fixtures").fetch(fixture["name"]), horizon, settings)]
      end
      platform = reference.fetch("platform")
      intro = "The reference outputs were produced by statsforecast #{reference["statsforecast_version"]} under " \
              "Python #{reference["python_version"]} with numpy #{reference["numpy_version"]} on " \
              "#{platform_name(platform["system"], platform["machine"])}, over a horizon of #{horizon} periods; " \
              "the differences below were measured at Foresight #{Foresight::VERSION}."
      by_method = REFERENCE_MODELS.map do |model, symbol|
        largest = comparisons.values.map { |comparison| comparison.forecasts[symbol] }.max
        [method_name(symbol), model, scientific(tolerance(symbol)), scientific(largest)]
      end
      by_fixture = comparisons.map do |name, comparison|
        [name, *REFERENCE_MODELS.values.map { |symbol| scientific(comparison.forecasts[symbol]) },
         scientific(comparison.alpha)]
      end
      [intro, table(["Method", "statsforecast model", "Tolerance", "Maximum absolute difference"], by_method),
       "Maximum absolute difference per fixture over the #{horizon} forecast periods of each method, and the " \
       "absolute difference of the SES smoothing parameter:",
       table(["Fixture", *REFERENCE_MODELS.values.map { |symbol| method_name(symbol) }, "SES `alpha`"],
             by_fixture)].join("\n\n")
    end

    def comparison(fixture, entries, horizon, settings)
      values = fixture["values"].map(&:to_f)
      options = settings.merge(season_length: fixture["season_length"])
      fits = REFERENCE_MODELS.transform_values { |symbol| Foresight::MODELS.fetch(symbol).new(values, options) }
      forecasts = fits.to_h do |model, fitted|
        recorded = entries.fetch(model).fetch("forecast")
        gaps = fitted.forecast(horizon).zip(recorded).map { |forecast, reference| (forecast - reference).abs }
        [REFERENCE_MODELS.fetch(model), gaps.max]
      end
      recorded_alpha = entries.fetch("SimpleExponentialSmoothingOptimized").fetch("alpha")
      Comparison.new(forecasts: forecasts,
                     alpha: (fits.fetch("SimpleExponentialSmoothingOptimized").alpha - recorded_alpha).abs)
    end

    def fixture_table(fixtures)
      rows = fixtures.map do |fixture|
        values = fixture["values"]
        demand_class = values.all?(&:zero?) ? "none, every value is zero" : Foresight.classify(values).demand_class.to_s
        [fixture["name"], values.size.to_s, fixture["season_length"].to_s, demand_class,
         provenance(fixture["provenance"])]
      end
      table(["Fixture", "Observations", "Season length", "Demand class", "Provenance"], rows)
    end

    def provenance(provenance)
      return "written by hand" if provenance["kind"] == "hand"

      "generated by `#{provenance["generator"]}` from seed #{provenance["seed"]}"
    end

    def processes(results)
      rows = results.fetch("config").fetch("processes").map do |process|
        seeds = process.fetch("seeds")
        [process["name"], definition(process), process["series"].to_s, process["length"].to_s,
         "#{seeds.first} to #{seeds.last}"]
      end
      table(["Process", "Demand in each period", "Series", "Observations per series", "Seeds"], rows)
    end

    def definition(process)
      if process["kind"] == "gaussian"
        "an independent Gaussian draw with mean #{process["mean"]} and standard deviation #{process["sd"]}, " \
        "censored at zero"
      else
        sizes, weights = process["sizes"].transpose
        "non-zero with probability #{process["occurrence"]}, independently of every other period; a non-zero " \
        "demand has size #{list(sizes)} with weights #{list(weights)}"
      end
    end

    def coverage(results)
      horizon = results.fetch("config").fetch("horizon")
      results.fetch("synthetic").fetch("processes").map do |record|
        ["#{record["name"]}: #{record["series"]} series, #{record["origins"]} pooled origins and " \
         "#{record["held_out"]} pooled held-out observations.",
         "Per-period quantiles:", coverage_table(record, "step", "Coverage", "True quantile"),
         "Lead-time quantiles:",
         coverage_table(record, "total", "Lead-time coverage",
                        "True quantile of the #{horizon}-period total")].join("\n\n")
      end.join("\n\n")
    end

    def coverage_table(record, kind, label, heading)
      statistic = kind == "step" ? "coverage" : "lead_time_coverage"
      discrete = record["levels"].all? { |entry| entry["truth"]["#{kind}_probability"] }
      header = ["Level", heading, *("Probability at or below it" if discrete), "#{label} of the true quantiles",
                "#{label} of the distribution quantiles", "Difference", "#{label} of the conformal quantiles",
                "Difference"]
      rows = record["levels"].map do |entry|
        truth = entry["truth"]
        [entry["level"].to_s, number(truth["#{kind}_quantile"]), *(number(truth["#{kind}_probability"]) if discrete),
         number(truth[statistic]),
         *STRATEGIES.flat_map do |strategy|
           [number(entry[strategy][statistic]), number(difference(entry[strategy][statistic], truth[statistic]))]
         end]
      end
      table(header, rows)
    end

    def summary(section, levels, real)
      classes = section.fetch("classes")
      parts = [exclusions(section), "Counts per demand class:", counts_table(classes),
               "Point accuracy per demand class and strategy:", accuracy_table(classes)]
      levels.each_with_index do |level, index|
        parts.push("Quantile level #{level}, with the bootstrap interval after each value:",
                   level_table(classes, index, real))
      end
      levels.each_with_index do |level, index|
        parts.push("Differences at level #{level}, the value under the distribution quantiles minus the value " \
                   "under the conformal quantiles, with the bootstrap interval after each difference:",
                   difference_table(classes, index, real))
      end
      parts.join("\n\n")
    end

    def exclusions(section)
      excluded = section.fetch("excluded")
      sentence = "Series set aside because they had no non-zero observation: #{section["excluded_all_zero"]}. " \
                 "Series set aside because the backtester raised an input error under one strategy: #{excluded.size}."
      return sentence if excluded.empty?

      items = excluded.map do |entry|
        "- `#{entry["id"]}` under the #{entry["strategy"]} quantiles: #{entry["message"]}"
      end
      "#{sentence}\n\n#{items.join("\n")}"
    end

    def counts_table(classes)
      rows = classes.map { |record| [record["demand_class"], *COUNTS.keys.map { |name| record[name].to_s }] }
      table(["Demand class", *COUNTS.values], rows)
    end

    def accuracy_table(classes)
      rows = classes.flat_map do |record|
        STRATEGIES.map do |strategy|
          [record["demand_class"], strategy, *%w[mae rmse mase].map { |name| number(record[strategy][name]) }]
        end
      end
      table(["Demand class", "Strategy", "MAE", "RMSE", "MASE"], rows)
    end

    def level_table(classes, index, real)
      rows = classes.flat_map do |record|
        STRATEGIES.map do |strategy|
          entry = record[strategy]["levels"][index]
          [record["demand_class"], strategy,
           *STATISTICS.map { |name| with_interval(entry[name], entry["#{name}_interval"], record["series"], real) },
           number(entry["scaled_pinball_zero"]), number(entry["scaled_pinball_nonzero"])]
        end
      end
      table(["Demand class", "Strategy", "Coverage", "Lead-time coverage", "Scaled pinball loss", "Zero part",
             "Non-zero part"], rows)
    end

    def difference_table(classes, index, real)
      rows = classes.map do |record|
        entry = record["difference"]["levels"][index]
        [record["demand_class"],
         *DIFFERENCES.map { |name| with_interval(entry[name], entry["#{name}_interval"], record["series"], real) }]
      end
      table(["Demand class", "Coverage error", "Lead-time coverage error", "Scaled pinball loss", "Coverage",
             "Lead-time coverage"], rows)
    end

    def with_interval(value, bounds, series, real)
      return UNDEFINED if value.nil? && bounds.nil?

      text = "#{number(value)} #{interval(bounds)}"
      real && bounds ? "#{text} (#{series} series)" : text
    end

    def configuration(results)
      config = results.fetch("config")
      bootstrap = config.fetch("bootstrap")
      rows = [["horizon", config["horizon"]], ["origins", config["origins"]], ["step", config["step"]],
              ["quantile levels", list(config["levels"])], ["sample paths", config["paths"]],
              ["calibration windows", config["windows"]], ["backtest seed", config["backtest_seed"]],
              ["bootstrap resamples", bootstrap["resamples"]], ["bootstrap seed", bootstrap["seed"]]]
      machine, system = results["ruby_platform"].split("-", 2)
      [table(%w[Setting Value], rows.map { |name, value| [name, value.to_s] }),
       "The study results were written by Foresight #{results["foresight_version"]} under Ruby " \
       "#{results["ruby_version"]} on #{platform_name(system, machine)}; the SHA-256 of the Online Retail II " \
       "subset they were computed from is `#{results["real_subset_sha256"]}`."].join("\n\n")
    end

    def worse(results)
      { "synthetic" => "Synthetic series:", "real" => "Online Retail II series:" }.map do |name, heading|
        entries = results.fetch(name).fetch("classes").flat_map { |record| worse_entries(record) }
        [heading, entries.empty? ? "- none" : entries.join("\n")].join("\n\n")
      end.join("\n\n")
    end

    def worse_entries(record)
      record["difference"]["levels"].each_with_index.flat_map do |entry, index|
        WORSE.filter_map do |name, (measure, wording)|
          gap = entry[name]
          next unless gap&.positive?

          statistic = name.delete_suffix("_error")
          distribution, conformal = STRATEGIES.map { |strategy| record[strategy]["levels"][index][statistic] }
          "- #{record["demand_class"]} at level #{entry["level"]}, #{measure}: #{number(distribution)} under the " \
          "distribution quantiles against #{number(conformal)} under the conformal quantiles, #{wording} " \
          "#{number(gap)} #{interval(entry["#{name}_interval"])}"
        end
      end
    end

    def worksheets(subset)
      source = subset.fetch("source")
      selection = subset.fetch("selection")
      calendar = subset.fetch("calendar")
      series = subset.fetch("series")
      rows = source["worksheets"].map do |worksheet|
        [worksheet["name"], worksheet["first_date"], worksheet["last_date"], worksheet["lines"].to_s]
      end
      classes = series.map { |entry| entry["demand_class"] }.tally
      counts = Foresight::EvaluationReport::DEMAND_CLASSES.map { |name| "#{classes.fetch(name.to_s, 0)} #{name}" }
      shortfalls = selection["shortfalls"].map do |shortfall|
        "#{shortfall["demand_class"]} with #{shortfall["included"]} eligible series, below the target of " \
        "#{shortfall["target"]}"
      end
      ["The zip file at #{source["url"]} has SHA-256 `#{source["zip_sha256"]}`; the workbook inside it has " \
       "SHA-256 `#{source["xlsx_sha256"]}` and holds #{rows.size} worksheets:",
       table(["Worksheet", "First transaction date", "Last transaction date", "Lines read"], rows),
       "Lines left uncounted because they copy lines of another worksheet: #{source["uncounted_copies"]}. The " \
       "trading calendar holds #{calendar.size} dates from #{calendar.first} to #{calendar.last}. The selection " \
       "used seed #{selection["seed"]}, a minimum length of #{selection["minimum_length"]} trading dates, a target " \
       "of #{selection["target_per_class"]} series per demand class and the product-code pattern " \
       "`#{selection["product_code_pattern"]}`. The subset holds #{series.size} series: #{list(counts)}. " \
       "Shortfalls: #{shortfalls.empty? ? "none" : list(shortfalls)}."].join("\n\n")
    end

    def packages(paths)
      paths.map do |path|
        pins = read(path).lines(chomp: true).reject(&:empty?).map { |line| line.split("==", 2) }
        ["`#{path.delete_prefix("#{ROOT}/")}`:", table(%w[Package Version], pins)].join("\n\n")
      end.join("\n\n")
    end

    def table(header, rows)
      lines = ["| #{header.join(" | ")} |", "|#{"---|" * header.size}"]
      (lines + rows.map { |cells| "| #{cells.join(" | ")} |" }).join("\n")
    end

    def number(value)
      return UNDEFINED if value.nil?

      rounded = value.round(PLACES)
      (rounded.zero? ? rounded.abs : rounded).to_s
    end

    def interval(bounds)
      bounds ? "[#{bounds.map { |bound| number(bound) }.join(", ")}]" : UNDEFINED
    end

    def difference(value, reference)
      value - reference if value && reference
    end

    def scientific(value)
      return "0" if value.zero?

      mantissa, exponent = format("%.2e", value).split("e")
      "#{mantissa.sub(/\.?0+\z/, "")}e#{exponent.to_i}"
    end

    def list(items)
      words = items.map(&:to_s)
      return words.join(" and ") if words.size <= 2

      "#{words[0...-1].join(", ")} and #{words.last}"
    end

    def method_name(symbol)
      Foresight::MODELS.fetch(symbol).name.split("::").last
    end

    def tolerance(symbol)
      symbol == :ses ? SES_TOLERANCE : DETERMINISTIC_TOLERANCE
    end

    def platform_name(system, machine)
      "#{SYSTEMS.fetch(system.downcase[/\A[a-z]+/]) { system }} (#{machine})"
    end

    def read(path)
      File.read(path)
    rescue SystemCallError => e
      raise Error, "cannot read #{path}: #{e.message}"
    end

    def read_json(path)
      JSON.parse(read(path))
    rescue JSON::ParserError => e
      raise Error, "cannot read #{path}: #{e.message}"
    end

    def write(path, text)
      temporary = "#{path}.tmp"
      File.write(temporary, text)
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary)
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    Render.run
  rescue Render::Error => e
    abort e.message
  end
end
