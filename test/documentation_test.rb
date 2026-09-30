# frozen_string_literal: true

require "test_helper"
require "json"
require "tmpdir"
require "foresight"
require_relative "../validation/render"

class DocumentationTest < Minitest::Test
  ROOT = File.dirname(__dir__)
  LIB = File.join(ROOT, "lib")
  README = File.join(ROOT, "README.md")
  METHODOLOGY = File.join(ROOT, "docs", "methodology.md")
  VALIDATION = File.join(ROOT, "docs", "validation.md")
  SUBSET_FILE = File.join(ROOT, "data", "online_retail_ii_subset.json")
  REFERENCE_FILE = File.join(ROOT, "data", "reference_outputs.json")
  RESULTS_FILE = File.join(ROOT, "validation", "study_results.json")
  REQUIREMENTS_FILES = %w[dev/reference/requirements.txt dev/retail/requirements.txt].freeze
  FENCE = /^```(\w*)\n(.*?)^```$/m
  LINK = /\[[^\]]*\]\(([^)\s]+)\)/
  AUTHORS = /[A-Z][A-Za-z]+(?:, [A-Z][A-Za-z]+)*(?: and [A-Z][A-Za-z]+)?/
  CITATION = /(#{AUTHORS.source})(?:'s)?(?: et al\.)? \(?(\d{4})(?:, [^)]*)?\)/
  REFERENCE = /\A- (.+?) \((\d{4})\)\. /
  OWN_CHOICE = "Foresight's own choice"
  REVISION = /\A- [0-9a-f]{7,40}: \S.*\z/
  STRATEGIES = %w[distribution conformal].freeze
  STATISTICS = %w[coverage lead_time_coverage scaled_pinball].freeze
  DIFFERENCES = %w[coverage_error lead_time_coverage_error scaled_pinball coverage lead_time_coverage].freeze
  WORSE = { "coverage_error" => "coverage", "lead_time_coverage_error" => "lead-time coverage",
            "scaled_pinball" => "scaled pinball loss" }.freeze
  WORSE_ENTRY = Regexp.new('\A- (\w+) at level ([\d.]+), (coverage|lead-time coverage|scaled pinball loss): (\S+) ' \
                           'under the distribution quantiles against (\S+) under the conformal quantiles, ' \
                           '(?:further from the level|larger) by (\S+) (\[\S+, \S+\]|undefined)\z')
  COUNT_FIELDS = %w[series origins held_out zero_held_out nonzero_held_out excluded_origins zero_scale_origins].freeze
  COUNTS_HEADER = "| Demand class | Series | Origins | Held-out observations | Zero held-out observations | " \
                  "Non-zero held-out observations | Excluded origins | Origins with an undefined MASE |"
  ACCURACY_HEADER = "| Demand class | Strategy | MAE | RMSE | MASE |"
  LEVEL_HEADER = "| Demand class | Strategy | Coverage | Lead-time coverage | Scaled pinball loss | Zero part | " \
                 "Non-zero part |"
  DIFFERENCE_HEADER = "| Demand class | Coverage error | Lead-time coverage error | Scaled pinball loss | Coverage | " \
                      "Lead-time coverage |"
  PARITY_HEADER = "| Method | statsforecast model | Tolerance | Maximum absolute difference |"
  METHODS = %w[Naive SeasonalNaive SES CrostonClassic CrostonSBA TSB].freeze
  POSITIONING = [
    "probabilistic demand forecasting",
    "Ruby and Rails developers who forecast demand, such as orders, stock or capacity",
    "prophet-rb", "single Stan-based model", "CrostonClassic, CrostonSBA and TSB",
    "demand classification with automatic model selection", "quantiles as the default output of every method",
    "modeled on the simple API of prophet-rb",
    "how much to stock, staff or provision need calibrated demand distributions",
    "point forecasts mislead for intermittent demand", "intermittent and lumpy demand classes",
    "the quantiles at a level q are calibrated when they cover a proportion q of the observed outcomes",
    "Foresight is a prototype", "is not implemented"
  ].freeze
  INSTALLATION = [
    "Linux and macOS", "zero runtime dependencies",
    'gem "foresight", git: "https://github.com/ojuschugh1/foresight"', "gem build foresight.gemspec",
    "gem install ./foresight-#{Foresight::VERSION}.gem"
  ].freeze
  SUMMARY = [
    "Naive, SeasonalNaive and SES", "CrostonClassic, CrostonSBA and TSB", "classifier", "1.32", "0.49",
    "automatic selector", "distribution strategy", "conformal strategy", "backtester", "statsforecast 2.1.1",
    "calibration study", "[docs/methodology.md](docs/methodology.md)", "[docs/validation.md](docs/validation.md)"
  ].freeze
  PRIOR_WORK = [
    "Croston, J. D. (1972). Forecasting and stock control for intermittent demands.",
    "Syntetos, A. A. and Boylan, J. E. (2005). The accuracy of intermittent demand estimates.",
    "Syntetos, A. A., Boylan, J. E. and Croston, J. D. (2005). On the categorization of demand patterns.",
    "Teunter, R. H., Syntetos, A. A. and Babai, M. Z. (2011). Intermittent demand: Linking forecasting to " \
    "inventory obsolescence.",
    "Kolassa, S. (2016). Evaluating predictive count data distributions in retail sales forecasting.",
    "Svetunkov, I. and Boylan, J. E. (2023). iETS: State space model for intermittent demand forecasting."
  ].freeze
  API_HEADINGS = [
    "### Foresight.forecast(series, **options)", "### Foresight.classify(series)",
    "### Foresight.backtest(series, horizon:, origins:, step: nil, **options)",
    "### Foresight.evaluate(collection, **options)", "### Foresight::Backtester",
    "### Foresight::EvaluationReport.aggregate(entries, horizon:, levels:)", "### Foresight::InputError"
  ].freeze
  ROADMAP = [
    /\AThe ETS family: trend, damped trend, additive and multiplicative seasonality/,
    /\ATheta, CrostonOptimized, ADIDA and IMAPA/, /\AiETS-style intermittent state-space models/,
    /\ADistribution-aware conformal recalibration of quantiles/, /\AValidation-driven \(data-driven\) model selection/,
    /\AThe inventory decision layer: service-level policies and simulated inventory evaluation/,
    /\AThe multi-dataset calibration benchmark/, /\ARandomized PIT diagnostics for discrete predictive distributions/,
    /\ANumo, Apache Arrow and Rover data adapters, and charting helpers/
  ].freeze
  EXCLUDED_WORDS = ["ARIMA", "neural", "foundation model", "multivariate", "hierarchical", "hosted service",
                    "Windows"].freeze
  METHODOLOGY_STATEMENTS = [
    "| Method | Initialization | Smoothing parameters and defaults | Optimization bounds | Minimum history | " \
    "Point forecast for period `h` |",
    "returns a local minimizer",
    "Automatic selection has a minimum history of one observation",
    "an ADI of 1.32 and a CV squared of 0.49",
    "| Model | Residuals `e_t` | Number of residuals `r` | Per-step factor `v_h` | Total factor `V_H` |",
    "no mean subtracted", "2 for Naive and SES, and the season length plus 1 for SeasonalNaive",
    "| CrostonClassic | `min(1, 1 / z_I)` |", "| CrostonSBA | `min(1, (1 - alpha / 2) / z_I)` |",
    "| TSB | `z_P`, clamped to `[0, 1]` |", "`p * mean(sizes)`",
    "3 / sqrt(N)", "1 - 2 exp(-18)",
    "| Aspect | statsforecast 2.1.1 | Foresight |",
    "the point forecast minus the smallest absolute window error",
    "statsforecast's linear interpolation at the same level returns the point forecast",
    "median of the predictive distribution", "(Kolassa 2016)", "(Svetunkov and Boylan 2023)", "service level",
    "Assumptions: the predictive distribution of each period is Gaussian, centered on the point forecast and " \
    "censored at zero; the residual variance is constant over time",
    "Assumptions: the demand of each period of the horizon is zero with probability `1 - p`",
    "the periods are independent of each other; `p` is constant over the horizon",
    "Assumptions: the absolute forecast errors of future periods follow the distribution of the absolute errors " \
    "recorded on the calibration windows, and they are symmetric around the point forecast",
    "divided by the scale", "zero part", "non-zero part",
    "The operations that take a seed are `Foresight.forecast`, `Foresight.backtest`, `Foresight.evaluate` and " \
    "`Foresight::Backtester.new`"
  ].freeze
  CONFORMAL_ASPECTS = ["Window placement", "Default and minimum windows", "History too short", "Clamping",
                       "Lead-time quantile", "Quantile rule", "Level 0.5"].freeze
  VALIDATION_STATEMENTS = [
    "1e-5 for SES", "TSB has no default smoothing parameters in statsforecast",
    "SeasonalNaive with fewer observations than the season length raises an input error in Foresight",
    "neither affects a fixture",
    "The calibration study is a first study. Its only real dataset is Online Retail II, and the multi-dataset " \
    "calibration benchmark",
    "planned and not built", "No fixture is derived from Online Retail II",
    "the bootstrap treats the series as independent units and does not account for demand shocks shared across " \
    "the products of one retailer",
    "9 December 2011", "anti-conservative", "blocks of dates", "kink at zero",
    "`bundle exec rake reproduce`", "`python dev/reference/generate.py`", "`python dev/retail/extract.py`",
    "`ruby -Ilib dev/retail/select.rb`", "network access"
  ].freeze
  CAVEATS = {
    "### Synthetic series" => ["SBA factor", "large-interval limit of the exact bias factor", "0.5 level",
                               "point forecast minus the smallest window error"],
    "### Online Retail II series" => ["9 December 2011", "same 70 trading dates", "SBA factor", "0.5 level"]
  }.freeze

  def test_the_quickstart_prints_exactly_the_output_the_readme_shows
    code, output = quickstart_blocks

    assert_equal %w[date foresight], code.scan(/^require "([^"]+)"$/).flatten
    assert_includes code, "Date.new("
    assert_match(/Foresight\.forecast\(series, count: \d+\)/, code)
    refute_includes code, "model:"
    %w[forecast quantiles lead_time_quantiles model reason].each { |field| assert_includes code, "result.#{field}" }
    Dir.mktmpdir do |dir|
      path = File.join(dir, "quickstart.rb")
      File.write(path, code)
      stdout, stderr, status = run_ruby("-I", LIB, path, chdir: dir)

      assert status.success?, stderr
      assert_empty stderr
      assert_equal output, stdout
    end
  end

  def test_the_positioning_thesis_and_prototype_status_precede_the_installation_heading
    before = before_heading(readme, "## Installation")

    POSITIONING.each { |statement| assert_includes before, statement }
  end

  def test_the_installation_section_states_the_ruby_version_the_platforms_and_the_dependencies
    section = section_of(readme, "## Installation")
    minimum = gemspec.required_ruby_version.requirements.map(&:last).min.to_s

    assert_includes section, "Ruby #{minimum} or newer"
    INSTALLATION.each { |statement| assert_includes section, statement }
  end

  def test_the_methodology_summary_names_every_component_and_links_to_both_documents
    section = section_of(readme, "## Methodology")

    SUMMARY.each { |statement| assert_includes section, statement }
  end

  def test_the_usage_section_documents_every_public_entry_point
    section = section_of(readme, "## Usage")

    API_HEADINGS.each { |heading| assert_includes section, "#{heading}\n" }
    Foresight::Options.forecast({}).each_key { |name| assert_includes section, "| `#{name}` |" }
  end

  def test_the_prior_work_names_smooth_and_the_six_works_and_marks_iets_as_planned
    section = section_of(readme, "## Prior work")

    assert_includes section, "the R package smooth"
    assert_includes section, "iETS"
    PRIOR_WORK.each { |citation| assert_includes section, "- #{citation} " }
    assert_includes section, "iETS-style models are planned and not implemented"
  end

  def test_the_roadmap_lists_nine_planned_and_unbuilt_items_and_the_exclusions_stay_out_of_it
    roadmap = section_of(readme, "## Roadmap")
    entries = roadmap.lines.grep(/\A- /).map { |line| line.chomp.delete_prefix("- ") }
    excluded = section_of(readme, "## Excluded from the prototype")

    assert_equal ROADMAP.size, entries.size, entries.inspect
    ROADMAP.zip(entries).each do |pattern, entry|
      assert_match pattern, entry
      assert entry.end_with?("Planned, not built."), entry
      EXCLUDED_WORDS.each { |word| refute_includes entry, word }
    end
    assert_includes roadmap, "Each item below is planned and not built."
    assert_includes excluded, "ARIMA, neural and foundation models, and multivariate and hierarchical forecasting " \
                              "are excluded from the prototype"
    assert_includes excluded, "any hosted service and Windows support"
    EXCLUDED_WORDS.each { |word| assert_equal excluded.scan(word).size, readme.scan(word).size, word }
  end

  def test_relative_links_resolve_to_files_of_the_repository
    { README => readme, METHODOLOGY => methodology, VALIDATION => validation }.each do |path, text|
      targets = text.scan(LINK).flatten.reject { |target| target.match?(/\A(?:[a-z]+:|#)/) }

      refute_empty targets, path
      targets.each do |target|
        file = File.expand_path(target.sub(/#.*\z/, ""), File.dirname(path))

        assert File.file?(file), "#{path} links to #{target}, which does not exist"
      end
    end
    assert_includes readme.scan(LINK).flatten, "docs/methodology.md"
    assert_includes readme.scan(LINK).flatten, "docs/validation.md"
  end

  def test_every_generated_region_equals_a_fresh_render
    regions = Render.regions
    found = Render::DOCUMENTS.flat_map do |name, path|
      text = File.read(path)

      assert_equal text, Render.fill(text, regions), name
      text.scan(Render::REGION)
    end

    assert_equal Render::REGIONS.sort, found.map(&:first).sort
    assert_equal ["defaults"], methodology.scan(Render::REGION).map(&:first)
    found.each { |name, body| assert_equal "#{regions.fetch(name)}\n", body, name }
  end

  def test_the_defaults_table_states_the_library_constants
    rows = table_rows(region_body(methodology, "defaults"), "| Setting | Default |").to_h
    settings = Foresight::Options.forecast({})

    assert_equal Foresight::DEFAULT_PATHS.to_s, rows.fetch("sample paths (`paths`)")
    assert_equal Foresight::DEFAULT_WINDOWS.to_s, rows.fetch("calibration windows (`windows`)")
    assert_equal Foresight::DEFAULT_SEED.to_s, rows.fetch("seed (`seed`)")
    assert_equal settings.fetch(:alpha_d).to_s, rows.fetch("TSB size smoothing parameter (`alpha_d`)")
    assert_equal settings.fetch(:alpha_p).to_s, rows.fetch("TSB occurrence smoothing parameter (`alpha_p`)")
  end

  def test_the_methodology_document_states_the_methods_the_rule_the_formulas_and_the_assumptions
    METHODOLOGY_STATEMENTS.each { |statement| assert_includes methodology, statement }
    methods = table_rows(methodology, METHODOLOGY_STATEMENTS.first)

    assert_equal METHODS, methods.map(&:first)
    methods.each { |cells| assert_equal 6, cells.size, cells.inspect }
    assert_operator methods.count { |cells| cells.include?("not applicable") }, :>=, 2
    factors = table_rows(methodology, METHODOLOGY_STATEMENTS[4])

    assert_equal %w[Naive SeasonalNaive SES], factors.map(&:first)
    aspects = table_rows(methodology, "| Aspect | statsforecast 2.1.1 | Foresight |")

    assert_equal CONFORMAL_ASPECTS, aspects.map(&:first)
    aspects.each { |cells| assert_equal 3, cells.size, cells.inspect }
  end

  def test_the_selection_rule_assigns_one_method_per_class_with_a_cited_support
    rows = table_rows(methodology, "| Demand class | Method | Support |")

    assert_equal [%w[smooth SES], %w[erratic CrostonSBA], %w[intermittent CrostonSBA], %w[lumpy CrostonSBA]],
                 rows.map { |cells| cells.first(2) }
    rows.each do |demand_class, _method, support|
      citations = support.scan(CITATION)

      refute_empty citations, demand_class
      citations.each { |authors, year| assert cited?(authors, year), "#{demand_class}: #{authors} (#{year})" }
    end
  end

  def test_every_row_of_the_choices_table_cites_the_reference_list_or_is_marked_as_foresight_own_choice
    rows = table_rows(section_of(methodology, "## Modeling and evaluation choices"), "| Choice | Source |")
    own = rows.select { |_choice, source| source.start_with?(OWN_CHOICE) }.map(&:first)

    assert_operator rows.size, :>=, 40
    rows.each do |choice, source|
      citations = source.scan(CITATION)

      refute_empty citations, choice unless source.start_with?(OWN_CHOICE)
      citations.each { |authors, year| assert cited?(authors, year), "#{choice}: #{authors} (#{year})" }
    end
    assert_equal 1, own.count { |choice| choice.include?("SBA factor") && choice.include?("occurrence probability") }
    assert_equal 1, own.count { |choice| choice.match?(/\ATen calibration windows/) }
    assert_operator references.size, :>=, 20
  end

  def test_the_validation_document_carries_the_fixed_statements_and_the_three_caveats
    VALIDATION_STATEMENTS.each { |statement| assert_includes validation, statement }
    interpretation = section_of(validation, "## Interpretation")

    assert_includes interpretation, "<!-- generated:worse -->"
    CAVEATS.each do |heading, phrases|
      prose = section_of(interpretation, heading)

      assert_operator prose.split.size, :>=, 100, heading
      phrases.each { |phrase| assert_includes prose, phrase, heading }
    end
  end

  def test_the_stated_tolerances_equal_the_test_constants
    rows = table_rows(region_body(validation, "parity"), PARITY_HEADER)

    assert_equal METHODS, rows.map(&:first)
    rows.each do |method, _model, tolerance, difference|
      expected = method == "SES" ? SES_TOLERANCE : DETERMINISTIC_TOLERANCE

      assert_equal expected, Float(tolerance), method
      assert_operator Float(difference), :<=, expected, method
    end
    assert_equal SES_TOLERANCE, Render::SES_TOLERANCE
    assert_equal DETERMINISTIC_TOLERANCE, Render::DETERMINISTIC_TOLERANCE
    assert_operator SES_TOLERANCE, :>, DETERMINISTIC_TOLERANCE
    assert_operator SES_TOLERANCE, :<=, 1e-4
    assert_includes region_body(validation, "parity"), "statsforecast #{statsforecast_pin} "
    assert_includes region_body(validation, "parity"), "Foresight #{Foresight::VERSION}."
  end

  def test_the_listed_pins_equal_the_requirements_files_and_the_regeneration_names_every_runtime
    parts = region_body(validation, "packages").split(%r{^(?=`dev/)})
    regeneration = section_of(validation, "## Regeneration")

    assert_equal REQUIREMENTS_FILES.size, parts.size
    REQUIREMENTS_FILES.zip(parts).each do |path, part|
      pins = File.readlines(File.join(ROOT, path), chomp: true).reject(&:empty?).map { |line| line.split("==", 2) }

      assert part.start_with?("`#{path}`:\n"), part.lines.first
      assert_equal pins, table_rows(part, "| Package | Version |"), path
    end
    assert_includes regeneration, "Python #{reference.fetch("python_version")}"
    assert_includes regeneration, "version #{statsforecast_pin}"
    File.read(File.join(ROOT, "Gemfile")).scan(/^gem "(\w+)", "([\d.]+)"$/) do |name, version|
      assert_includes regeneration, "#{name} #{version}"
    end
  end

  def test_the_stated_configuration_equals_the_committed_study_configuration
    config = results.fetch("config")
    region = region_body(validation, "configuration")
    levels = config["levels"]
    before_first_origin = 1 + config["windows"] * config["horizon"]
    needed = before_first_origin + config["horizon"] + config["step"] * (config["origins"] - 1)
    expected = {
      "horizon" => config["horizon"], "origins" => config["origins"], "step" => config["step"],
      "quantile levels" => "#{levels[0...-1].join(", ")} and #{levels.last}", "sample paths" => config["paths"],
      "calibration windows" => config["windows"], "backtest seed" => config["backtest_seed"],
      "bootstrap resamples" => config["bootstrap"]["resamples"], "bootstrap seed" => config["bootstrap"]["seed"]
    }

    assert_equal expected.transform_values(&:to_s), table_rows(region, "| Setting | Value |").to_h
    assert_includes region, "Foresight #{results["foresight_version"]} under Ruby #{results["ruby_version"]}"
    assert_includes region, "`#{results["real_subset_sha256"]}`"
    assert_includes validation, "#{needed} observations under this configuration (#{before_first_origin} before " \
                                "the first origin)"
    assert_includes validation, "Random.new(#{config["bootstrap"]["seed"]} + k)"
    config["processes"].each do |process|
      assert_includes region_body(validation, "processes"), "| #{process["name"]} |"
      assert_includes region_body(validation, "coverage"), "#{process["name"]}: #{process["series"]} series"
    end
  end

  def test_the_validation_document_carries_the_attribution_and_the_selection_rule_of_the_subset
    section = section_of(validation, "## Online Retail II subset")
    attribution = subset.fetch("attribution")
    selection = subset.fetch("selection")
    modifications = attribution.fetch("modifications")

    [attribution["title"], attribution["creator"], attribution["citation"], "https://doi.org/#{attribution["doi"]}",
     attribution["license"], attribution["license_url"]].each { |field| assert_includes section, field }
    modifications[0...-1].each { |modification| assert_includes section, modification }
    assert_includes section, modifications.last[/\A.*deterministic selection/]
    assert_includes section, "`#{selection["product_code_pattern"]}`"
    assert_includes section, "at least #{selection["minimum_length"]} trading dates"
    assert_includes section, "`#{selection["seed"]}:` followed by the stock code"
    assert_includes section, "the first #{selection["target_per_class"]} are taken"
  end

  def test_the_summary_tables_print_every_count_metric_part_and_interval_of_the_committed_results
    assert_summary_tables(results.fetch("synthetic"), region_body(validation, "summary-synthetic"), false)
    assert_summary_tables(results.fetch("real"), region_body(validation, "summary-real"), true)
  end

  def test_the_list_of_comparisons_where_the_distribution_quantiles_do_worse_matches_the_results
    synthetic, real = region_body(validation, "worse").split("Online Retail II series:")

    assert synthetic.start_with?("Synthetic series:\n")
    { "synthetic" => [synthetic, "### Synthetic series"], "real" => [real, "### Online Retail II series"] }
      .each do |name, (part, heading)|
      prose = section_of(section_of(validation, "## Interpretation"), heading)
      listed = part.lines.map(&:chomp).grep(/\A- /)
      expected = results[name]["classes"].flat_map do |record|
        record["difference"]["levels"].flat_map do |entry|
          WORSE.filter_map do |statistic, measure|
            "#{record["demand_class"]} at level #{entry["level"]}, #{measure}" if entry[statistic]&.positive?
          end
        end
      end

      if expected.empty?
        assert_equal ["- none"], listed, name
      else
        assert_equal expected, listed.map { |line| line[/\A- (.*?):/, 1] }, name
      end
      listed.grep_v("- none").each do |line|
        demand_class, level, _measure, distribution, conformal = line.match(WORSE_ENTRY).captures

        assert_includes prose, demand_class, line
        assert_includes prose, level, line
        assert_includes prose, distribution, line
        assert_includes prose, conformal, line
      end
    end
  end

  def test_the_revisions_section_holds_no_revisions_or_entries_with_a_short_hash_and_a_reason
    entries = section_of(validation, "## Revisions").lines.map(&:chomp).reject(&:empty?)

    refute_empty entries
    return if entries == ["No revisions."]

    entries.each { |entry| assert_match REVISION, entry }
  end

  private

  def readme
    @readme ||= File.read(README)
  end

  def methodology
    @methodology ||= File.read(METHODOLOGY)
  end

  def validation
    @validation ||= File.read(VALIDATION)
  end

  def results
    @results ||= JSON.parse(File.read(RESULTS_FILE))
  end

  def subset
    @subset ||= JSON.parse(File.read(SUBSET_FILE))
  end

  def reference
    @reference ||= JSON.parse(File.read(REFERENCE_FILE))
  end

  def gemspec
    Gem::Specification.load(File.join(ROOT, "foresight.gemspec"))
  end

  def statsforecast_pin
    File.read(File.join(ROOT, REQUIREMENTS_FILES.first))[/^statsforecast==(\S+)$/, 1]
  end

  def heading?(line, depth)
    marks = line[/\A#+(?= )/]
    marks && marks.size <= depth
  end

  def section_of(text, heading)
    lines = text.lines
    start = lines.index("#{heading}\n")

    refute_nil start, "#{heading} is missing"
    lines[(start + 1)..].take_while { |line| !heading?(line, heading[/\A#+/].size) }.join
  end

  def before_heading(text, heading)
    lines = text.lines
    start = lines.index("#{heading}\n")

    refute_nil start, "#{heading} is missing"
    lines[0...start].join
  end

  def region_body(text, name)
    body = text[%r{^<!-- generated:#{name} -->\n(.*?)^<!-- /generated:#{name} -->$}m, 1]

    refute_nil body, "the generated region #{name} is missing"
    body
  end

  def quickstart_blocks
    blocks = section_of(readme, "## Quickstart").scan(FENCE)
    index = blocks.index { |language, _body| language == "ruby" }

    refute_nil index, "the quickstart has no ruby block"
    assert_operator blocks.size, :>, index + 1, "the quickstart shows no output block"
    assert_equal "", blocks[index + 1].first
    [blocks[index].last, blocks[index + 1].last]
  end

  def cells(line)
    line.chomp.delete_prefix("|").delete_suffix("|").split(" | ").map(&:strip)
  end

  def tables(text, header)
    lines = text.lines
    lines.each_index.select { |index| lines[index] == "#{header}\n" }.map do |index|
      lines[(index + 2)..].take_while { |line| line.start_with?("|") }.map { |line| cells(line) }
    end
  end

  def table_rows(text, header)
    found = tables(text, header)

    assert_equal 1, found.size, "#{header} appears #{found.size} times"
    found.first
  end

  def references
    @references ||= section_of(methodology, "## References").lines.grep(/\A- /).map do |line|
      match = line.match(REFERENCE)

      refute_nil match, line
      [match[1], match[2]]
    end
  end

  def cited?(authors, year)
    surnames = authors.split(/, | and /)
    references.any? { |names, cited| cited == year && surnames.all? { |surname| names.include?(surname) } }
  end

  def rendered(value)
    return "undefined" if value.nil?

    rounded = value.round(3)
    (rounded.zero? ? rounded.abs : rounded).to_s
  end

  def with_interval(value, bounds, series, real)
    return "undefined" if value.nil? && bounds.nil?

    text = "#{rendered(value)} #{bounds ? "[#{bounds.map { |bound| rendered(bound) }.join(", ")}]" : "undefined"}"
    real && bounds ? "#{text} (#{series} series)" : text
  end

  def assert_summary_tables(section, region, real)
    classes = section.fetch("classes")
    levels = results.fetch("config").fetch("levels")
    excluded = section.fetch("excluded")

    assert_includes region, "Series set aside because they had no non-zero observation: " \
                            "#{section["excluded_all_zero"]}. Series set aside because the backtester raised an " \
                            "input error under one strategy: #{excluded.size}."
    excluded.each do |entry|
      assert_includes region, "- `#{entry["id"]}` under the #{entry["strategy"]} quantiles: #{entry["message"]}"
    end
    assert_equal classes.map { |record| [record["demand_class"], *COUNT_FIELDS.map { |name| record[name].to_s }] },
                 table_rows(region, COUNTS_HEADER)
    assert_equal classes.flat_map { |record| accuracy_rows(record) }, table_rows(region, ACCURACY_HEADER)
    level_tables = tables(region, LEVEL_HEADER)
    difference_tables = tables(region, DIFFERENCE_HEADER)

    assert_equal levels.size, level_tables.size
    assert_equal levels.size, difference_tables.size
    levels.each_with_index do |level, index|
      assert_includes region, "Quantile level #{level}, with the bootstrap interval after each value:"
      assert_includes region, "Differences at level #{level}, the value under the distribution quantiles minus the " \
                              "value under the conformal quantiles, with the bootstrap interval after each difference:"
      assert_equal classes.flat_map { |record| level_rows(record, index, real) }, level_tables[index], level
      assert_equal classes.map { |record| difference_row(record, index, real) }, difference_tables[index], level
    end
  end

  def accuracy_rows(record)
    STRATEGIES.map do |strategy|
      [record["demand_class"], strategy, *%w[mae rmse mase].map { |name| rendered(record[strategy][name]) }]
    end
  end

  def level_rows(record, index, real)
    STRATEGIES.map do |strategy|
      entry = record[strategy]["levels"][index]
      [record["demand_class"], strategy,
       *STATISTICS.map { |name| with_interval(entry[name], entry["#{name}_interval"], record["series"], real) },
       rendered(entry["scaled_pinball_zero"]), rendered(entry["scaled_pinball_nonzero"])]
    end
  end

  def difference_row(record, index, real)
    entry = record["difference"]["levels"][index]
    [record["demand_class"],
     *DIFFERENCES.map { |name| with_interval(entry[name], entry["#{name}_interval"], record["series"], real) }]
  end
end
