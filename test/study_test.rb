# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "digest"
require "fileutils"
require "json"
require "tmpdir"
require "foresight"
require_relative "../validation/render"
require_relative "../validation/study"

class StudyTest < Minitest::Test
  SEED = 86_028_121
  ROOT = File.dirname(__dir__)
  LIB = File.join(ROOT, "lib")
  STUDY_FILE = File.join(ROOT, "validation", "study.rb")
  RESULTS_FILE = File.join(ROOT, "validation", "study_results.json")
  CONFIG_FILE = File.join(ROOT, "validation", "study_config.json")
  SUBSET_FILE = File.join(ROOT, "data", "online_retail_ii_subset.json")
  VALIDATION_FILES = %w[bootstrap study truth].map { |name| File.join(ROOT, "validation", "#{name}.rb") }.freeze
  STRATEGIES = %w[distribution conformal].freeze
  STATISTICS = %w[coverage lead_time_coverage scaled_pinball].freeze
  DIFFERENCES = %w[coverage_error lead_time_coverage_error scaled_pinball coverage lead_time_coverage].freeze
  DEMAND_CLASSES = %w[smooth erratic intermittent lumpy].freeze
  PARTS = %w[scaled_pinball scaled_pinball_zero scaled_pinball_nonzero].freeze
  MEANS = %w[mae rmse mase].freeze
  COUNTS = %w[origins held_out zero_held_out nonzero_held_out].freeze
  LEVEL_POOL = [0.1, 0.25, 0.5, 0.8, 0.9, 0.95].freeze
  TOLERANCE = 1e-12
  KEYS = %w[id level coverage covered held_out origins scaled_pinball series config seeds message classes].freeze
  FLOATS = [0.0, -0.0, 1.0, 0.5, Float::MIN, Float::MIN * Float::EPSILON, Float::MAX, -Float::MAX, 1e300, -1e-300,
            Float::EPSILON, 0.1, 1 / 3.0, 2.0**53, 20_260_925.0].freeze
  INTEGERS = [0, 1, -1, 7, 200, 10_000, 20_260_925, 2**31, 2**53, 2**64, -(2**70), 10**30].freeze
  STRINGS = ["", "smooth-gaussian/10001", "85123A", "a\"b", "back\\slash", "tab\tnewline\n", "\u00e9\u4e2d\u6587",
             "\u2028", "/", "0.1.0", "arm64-darwin"].freeze
  SETTINGS = {
    "horizon" => 7, "origins" => 2, "step" => 7,
    "levels" => [0.5, 0.8, 0.9, 0.95],
    "paths" => 200, "windows" => 2, "backtest_seed" => 20_260_925,
    "bootstrap" => { "resamples" => 50, "seed" => 20_260_926 }
  }.freeze
  PROCESSES = [
    { "name" => "smooth-gaussian", "kind" => "gaussian", "mean" => 50.0, "sd" => 10.0,
      "series" => 2, "length" => 60, "first_seed" => 10_001 },
    { "name" => "intermittent-bernoulli", "kind" => "bernoulli", "occurrence" => 0.25,
      "sizes" => [[1, 1], [2, 1], [3, 1], [4, 1], [5, 1]], "series" => 2, "length" => 60, "first_seed" => 30_001 }
  ].freeze
  REDUCED_CONFIG = SETTINGS.merge("processes" => PROCESSES).freeze
  GUARDS = [
    [{ "name" => "dense-bernoulli", "kind" => "bernoulli", "occurrence" => 0.9375, "sizes" => [[5, 1]],
       "series" => 2, "length" => 60, "first_seed" => 1 }, "ses", "a smooth model"],
    [{ "name" => "sparse-gaussian", "kind" => "gaussian", "mean" => 0.0, "sd" => 1.0,
       "series" => 2, "length" => 60, "first_seed" => 1 }, "croston_sba", "an intermittent model"]
  ].freeze
  CALENDAR_DATES = 80
  SHORT_CODE = "10003"
  SUBSET_SHAPES = [["10001", 0, :intermittent], ["10002", 20, :intermittent], [SHORT_CODE, 60, :intermittent],
                   ["10004", 10, :smooth], ["10005", 10, :zero]].freeze
  RESULT_KEYS = %w[foresight_version ruby_version ruby_platform real_subset_sha256 config synthetic real].freeze
  SECTION_KEYS = %w[series excluded excluded_all_zero classes].freeze
  SERIES_KEYS = %w[id process seed stock_code demand_class origins held_out zero_held_out nonzero_held_out
                   distribution conformal].freeze
  STRATEGY_KEYS = %w[mae rmse mase levels].freeze
  SERIES_LEVEL_KEYS = %w[level scaled_pinball scaled_pinball_zero scaled_pinball_nonzero coverage lead_time_coverage
                         covered lead_time_hits].freeze
  CLASS_KEYS = %w[demand_class series origins held_out zero_held_out nonzero_held_out excluded_origins
                  zero_scale_origins bootstrap_seed distribution conformal difference].freeze
  CLASS_LEVEL_KEYS = %w[level scaled_pinball scaled_pinball_zero scaled_pinball_nonzero coverage lead_time_coverage
                        coverage_interval lead_time_coverage_interval scaled_pinball_interval].freeze
  DIFFERENCE_KEYS = ["level", *DIFFERENCES.flat_map { |name| [name, "#{name}_interval"] }].freeze
  PROCESS_KEYS = %w[name series origins held_out levels].freeze
  TRUTH_KEYS = %w[coverage lead_time_coverage step_quantile total_quantile step_probability
                  total_probability].freeze
  EXCLUSION_KEYS = %w[id strategy message].freeze
  POOLED_MINIMUMS = { "held_out" => 1000, "origins" => 200 }.freeze

  def test_study_results_shaped_documents_round_trip_through_json
    seen = []
    each_seed(200) do |seed, random|
      document = random_document(random)
      about = "seed #{seed}: #{document.inspect}"
      parsed = JSON.parse(JSON.generate(document))

      assert_equal document, parsed, about
      assert_equal typed(document), typed(parsed), about
      leaves = leaves_of(document)
      seen << :nil if leaves.include?(nil)
      seen << :negative_zero if leaves.any? { |leaf| Float === leaf && leaf.zero? && leaf.to_s.start_with?("-") }
      seen << :subnormal if leaves.any? { |leaf| Float === leaf && !leaf.zero? && leaf.abs < Float::MIN }
      seen << :huge if leaves.any? { |leaf| Float === leaf && leaf.abs >= 1e300 }
      seen << :big_integer if leaves.any? { |leaf| Integer === leaf && leaf.abs >= 2**62 }
      seen << :non_ascii if leaves.any? { |leaf| String === leaf && !leaf.ascii_only? }
      seen << :nested if depth_of(document) >= 3
    end
    assert_equal %i[big_integer huge negative_zero nested nil non_ascii subnormal], seen.uniq.sort, "seed #{SEED}"
  end

  def test_bootstrap_intervals_equal_an_independent_paired_percentile_bootstrap
    seen = []
    each_seed(120) do |seed, random|
      levels = LEVEL_POOL.sample(random.rand(1..4), random: random).sort
      records = random_records(random, levels)
      resamples = random.rand(8).zero? ? random.rand(1..3) : random.rand(1..400)
      bootstrap_seed = random.rand(2**32)
      about = "seed #{seed}: #{records.inspect} levels #{levels.inspect} resamples #{resamples} " \
              "bootstrap seed #{bootstrap_seed}"
      intervals = Bootstrap.intervals(records, levels: levels, resamples: resamples, seed: bootstrap_seed)

      assert_equal typed(oracle_intervals(records, levels, resamples, bootstrap_seed)), typed(intervals), about
      assert_equal typed(oracle_statistics(records, levels)), typed(Bootstrap.statistics(records, levels)), about
      bounds = flat_intervals(intervals)
      bounds.each do |name, interval|
        next if interval.nil?

        assert_equal [Float, Float], interval.map(&:class), "#{about} #{name}"
        assert_operator interval.first, :<=, interval.last, "#{about} #{name}"
      end
      if records.size < 2
        assert_equal [nil], bounds.values.uniq, about
        seen << :below_two
      else
        seen << (bounds.values.any?(&:nil?) ? :undefined : :all_defined)
        seen << :zero_divisor if records.any? { |record| record["origins"].zero? }
      end
      seen << :single_resample if resamples == 1
      seen << :several_levels if levels.size > 1
    end
    assert_equal %i[all_defined below_two several_levels single_resample undefined zero_divisor], seen.uniq.sort,
                 "seed #{SEED}"
  end

  def test_identical_records_give_intervals_that_collapse_onto_the_statistic_of_the_list
    seen = []
    each_seed(100) do |seed, random|
      levels = LEVEL_POOL.sample(random.rand(1..4), random: random).sort
      record = random_record(random, levels, 0)
      records = Array.new(random.rand(2..30)) { Marshal.load(Marshal.dump(record)) }
      resamples = random.rand(1..400)
      about = "seed #{seed}: #{record.inspect} copies #{records.size} levels #{levels.inspect} resamples #{resamples}"
      statistics = oracle_statistics(records, levels)
      intervals = Bootstrap.intervals(records, levels: levels, resamples: resamples, seed: random.rand(2**32))

      intervals.each do |name, by_level|
        by_level.each do |level, entries|
          entries.each do |key, interval|
            statistic = statistics[name][level][key.delete_suffix("_interval")]
            at = "#{about} #{name} #{level} #{key}"
            if statistic.nil?
              assert_nil interval, at
              seen << :undefined
            else
              assert_equal [statistic, statistic], interval, at
              seen << :defined
            end
          end
        end
      end
    end
    assert_equal %i[defined undefined], seen.uniq.sort, "seed #{SEED}"
  end

  def test_the_loader_returns_each_series_as_its_values_from_its_start_to_the_last_calendar_date
    Dir.mktmpdir do |dir|
      document = subset_document
      path = File.join(dir, "subset.json")
      File.write(path, JSON.generate(document))
      calendar = document["calendar"]
      loaded = Study.load_subset(path)

      assert_equal document["series"].map { |entry| entry["stock_code"] }, loaded.map(&:id)
      assert_equal loaded.map(&:id), loaded.map(&:stock_code)
      assert_equal [[nil, nil]], loaded.map { |series| [series.process, series.seed] }.uniq
      document["series"].zip(loaded).each do |entry, series|
        assert_instance_of Study::Series, series, entry["stock_code"]
        assert_equal entry["values"], series.values, entry["stock_code"]
        assert_equal calendar.size - calendar.index(entry["start"]), series.values.size, entry["stock_code"]
      end
      assert_equal [80, 60, 20, 70, 70], loaded.map { |series| series.values.size }
    end
  end

  def test_a_study_run_reads_only_its_configuration_and_subset_and_loads_only_the_gem_and_the_standard_library
    with_study_files do |files|
      elsewhere = File.join(File.dirname(files[:output_path]), "in_process.json")
      script = <<~RUBY
        before = $LOADED_FEATURES.dup
        READS = []
        recorder = Module.new do
          %i[read binread readlines foreach open new].each do |name|
            define_method(name) do |path, *rest, **options, &block|
              READS << [path.to_s, (rest.first || options[:mode] || "r").to_s]
              super(path, *rest, **options, &block)
            end
          end
        end
        File.singleton_class.prepend(recorder)
        require #{STUDY_FILE.inspect}
        Study.run(config_path: #{files[:config_path].inspect}, subset_path: #{files[:subset_path].inspect},
                  output_path: #{files[:output_path].inspect})
        added = $LOADED_FEATURES - before
        require "rbconfig"
        require "json"
        puts JSON.generate([RbConfig::CONFIG["rubylibdir"], RbConfig::CONFIG["archdir"], added, READS])
      RUBY
      output, error, status = run_ruby("--disable-gems", "-I", LIB, "-e", script)

      assert status.success?, error
      rubylibdir, archdir, features, reads = JSON.parse(output)
      own = File.join(File.realpath(LIB), "")
      standard = [rubylibdir, archdir].map { |directory| File.join(File.realpath(directory), "") }
      paths = features.map { |feature| File.realpath(feature) }
      outside = paths.reject { |path| [own, *standard].any? { |directory| path.start_with?(directory) } }

      assert_equal VALIDATION_FILES.map { |file| File.realpath(file) }.sort, outside.sort, features.inspect
      assert_includes paths, File.realpath(File.join(LIB, "foresight.rb"))
      assert_equal reads, reads.select { |_path, mode| mode.start_with?("r") }
      assert_equal files.values_at(:config_path, :subset_path).sort, reads.map(&:first).uniq.sort
      Study.run(**files, output_path: elsewhere)
      assert_equal File.binread(elsewhere), File.binread(files[:output_path])
    end
  end

  def test_a_reduced_configuration_run_twice_writes_identical_bytes_that_round_trip
    with_study_files do |files|
      results = Study.run(**files)
      first = File.binread(files[:output_path])
      Study.run(**files)
      seeded = PROCESSES.map { |process| process.merge("seeds" => process_seeds(process)) }

      assert_equal first, File.binread(files[:output_path])
      assert_equal "#{JSON.pretty_generate(results)}\n", first
      assert_equal typed(results), typed(JSON.parse(first))
      assert_equal RESULT_KEYS, results.keys
      assert_equal [Foresight::VERSION, RUBY_VERSION, RUBY_PLATFORM,
                    Digest::SHA256.hexdigest(File.binread(files[:subset_path]))],
                   results.values_at("foresight_version", "ruby_version", "ruby_platform", "real_subset_sha256")
      assert_equal typed(REDUCED_CONFIG.merge("processes" => seeded)), typed(results["config"])
      assert_equal SECTION_KEYS + ["processes"], results["synthetic"].keys
      assert_equal SECTION_KEYS, results["real"].keys
    end
  end

  def test_the_reduced_results_list_every_series_with_its_counts_and_the_exclusions_of_the_run
    with_study_files do |files, subset|
      results = Study.run(**files)
      synthetic = results["synthetic"]
      real = results["real"]
      short = subset["series"].find { |entry| entry["stock_code"] == SHORT_CODE }
      message = assert_raises(Foresight::InputError) do
        Foresight.backtest(short["values"], strategy: :conformal, **backtest_settings)
      end.message

      assert_equal synthetic_ids, field(synthetic, "id")
      assert_equal synthetic_ids.map { |id| id.split("/") },
                   field(synthetic, "process").zip(field(synthetic, "seed").map(&:to_s))
      assert_equal [nil], field(synthetic, "stock_code").uniq
      assert_equal [[], 0], synthetic.values_at("excluded", "excluded_all_zero")
      assert_equal %w[smooth smooth intermittent intermittent], field(synthetic, "demand_class")
      assert_equal [{ "id" => SHORT_CODE, "strategy" => "conformal", "message" => message }], real["excluded"]
      assert_equal 1, real["excluded_all_zero"]
      assert_equal %w[10001 10002 10004], field(real, "id")
      assert_equal field(real, "id"), field(real, "stock_code")
      assert_equal [nil], (field(real, "process") + field(real, "seed")).uniq
      assert_equal %w[intermittent intermittent smooth], field(real, "demand_class")
      assert_series_records(synthetic, "synthetic", REDUCED_CONFIG)
      assert_series_records(real, "real", REDUCED_CONFIG)
    end
  end

  def test_the_reduced_class_records_recompute_from_their_series_records_with_paired_bootstrap_intervals
    with_study_files do |files|
      results = Study.run(**files)

      assert_equal [2, 0, 2, 0], assert_class_records(results["synthetic"], 0, "synthetic", REDUCED_CONFIG)
      assert_equal [1, 0, 2, 0], assert_class_records(results["real"], DEMAND_CLASSES.size, "real", REDUCED_CONFIG)
    end
  end

  def test_the_reduced_process_records_pool_each_process_and_carry_its_true_quantiles
    with_study_files do |files|
      assert_process_records(Study.run(**files)["synthetic"], REDUCED_CONFIG)
    end
  end

  def test_the_committed_results_parse_round_trip_and_match_the_schema
    text = File.binread(RESULTS_FILE)
    results = JSON.parse(text)
    parsed = JSON.parse(JSON.generate(results))
    config = committed_config
    seeded = config["processes"].map { |process| process.merge("seeds" => process_seeds(process)) }

    assert_equal results, parsed
    assert_equal typed(results), typed(parsed)
    assert text.end_with?("\n")
    refute text.end_with?("\n\n")
    assert_equal RESULT_KEYS, results.keys
    assert_equal Foresight::VERSION, results["foresight_version"]
    assert_match(/\A\d+\.\d+\.\d+\z/, results["ruby_version"])
    assert_match(/\A\S+-\S+\z/, results["ruby_platform"])
    assert_equal typed(config.merge("processes" => seeded)), typed(results["config"])
    assert_equal SECTION_KEYS + ["processes"], results["synthetic"].keys
    assert_equal SECTION_KEYS, results["real"].keys
    %w[synthetic real].each do |name|
      section = results[name]

      assert_kind_of Integer, section["excluded_all_zero"], name
      section["excluded"].each do |entry|
        assert_equal EXCLUSION_KEYS, entry.keys, name
        assert_includes STRATEGIES, entry["strategy"], name
        assert_equal [String, String], entry.values_at("id", "message").map(&:class), name
      end
      assert_equal DEMAND_CLASSES, section["classes"].map { |record| record["demand_class"] }, name
      assert_series_records(section, name, config)
    end
  end

  def test_the_committed_results_record_unique_seeds_the_subset_digest_and_enough_pooled_observations
    results = committed_results
    config = committed_config
    synthetic = results["synthetic"]
    real = results["real"]
    recorded = subset_series.to_h { |entry| [entry["stock_code"], entry["demand_class"]] }
    generated = config["processes"].flat_map do |process|
      process_seeds(process).map { |seed| "#{process["name"]}/#{seed}" }
    end
    seeds = field(synthetic, "seed")
    listed = field(synthetic, "id") + synthetic["excluded"].map { |entry| entry["id"] }

    assert_equal Digest::SHA256.file(SUBSET_FILE).hexdigest, results["real_subset_sha256"]
    assert_equal [Integer], seeds.map(&:class).uniq
    assert_equal seeds.uniq, seeds
    assert_equal field(synthetic, "id"), field(synthetic, "process").zip(seeds).map { |name, seed| "#{name}/#{seed}" }
    assert_empty listed - generated
    assert_equal generated.size, listed.size + synthetic["excluded_all_zero"]
    assert_equal [nil], field(synthetic, "stock_code").uniq
    assert_equal [nil], (field(real, "process") + field(real, "seed")).uniq
    assert_equal field(real, "id"), field(real, "stock_code")
    real["series"].each do |record|
      assert recorded.key?(record["id"]), "#{record["id"]} is not in the subset"
      assert_equal recorded[record["id"]], record["demand_class"], record["id"]
    end
    assert_equal recorded.size, real["series"].size + real["excluded"].size + real["excluded_all_zero"]
    assert_process_records(synthetic, config)
    synthetic["processes"].each do |record|
      POOLED_MINIMUMS.each { |name, minimum| assert_operator record[name], :>=, minimum, "#{record["name"]} #{name}" }
    end
  end

  def test_the_committed_class_records_recompute_from_their_series_records_with_seeded_intervals
    results = committed_results
    config = committed_config
    subset = subset_series.group_by { |entry| entry["demand_class"] }
    excluded = results["real"]["excluded"].map { |entry| entry["id"] }
    synthetic_counts = assert_class_records(results["synthetic"], 0, "synthetic", config)
    real_counts = assert_class_records(results["real"], DEMAND_CLASSES.size, "real", config)

    assert_equal results["synthetic"]["series"].size, synthetic_counts.sum
    assert_equal results["real"]["series"].size, real_counts.sum
    results["real"]["classes"].each do |record|
      members = subset.fetch(record["demand_class"], [])

      assert_equal members.count { |entry| !excluded.include?(entry["stock_code"]) }, record["series"],
                   record["demand_class"]
    end
  end

  def test_the_family_guard_stops_the_study_before_anything_is_written
    GUARDS.each do |process, model, family|
      with_study_files(SETTINGS.merge("processes" => [process])) do |files|
        dir = File.dirname(files[:output_path])
        File.write(files[:output_path], "kept\n")
        position = process["length"] - SETTINGS["horizon"] - SETTINGS["step"]
        error = assert_raises(Study::Error, process["name"]) { Study.run(**files) }

        assert_equal "#{process["name"]} seed 1, origin at position #{position}: automatic selection chose " \
                     "#{model}, #{family}", error.message
        assert_equal "kept\n", File.read(files[:output_path]), process["name"]
        assert_equal %w[study_config.json study_results.json subset.json], Dir.children(dir).sort, process["name"]
      end
    end
  end

  def test_an_unreadable_file_or_a_failing_backtest_stops_the_study_and_leaves_the_results_file_alone
    with_study_files do |files, subset|
      dir = File.dirname(files[:output_path])
      File.write(files[:output_path], "kept\n")
      calendar = subset["calendar"]
      unparsable = File.join(dir, "unparsable.json")
      File.write(unparsable, "{ not json")
      no_series = File.join(dir, "no_series.json")
      File.write(no_series, JSON.generate("calendar" => calendar))
      [File.join(dir, "missing.json"), unparsable].each do |path|
        %i[config_path subset_path].each do |name|
          error = assert_raises(Study::Error, "#{name} #{path}") { Study.run(**files, name => path) }

          assert error.message.start_with?("cannot read #{path}: "), error.message
        end
      end
      error = assert_raises(Study::Error) { Study.run(**files, subset_path: no_series) }

      assert error.message.start_with?("cannot read #{no_series}: "), error.message
      { "short_values.json" => [calendar.first, Array.new(calendar.size - 1, 1)],
        "unknown_start.json" => ["2010-12-31", Array.new(calendar.size, 1)] }.each do |name, (start, values)|
        path = File.join(dir, name)
        entry = { "stock_code" => "10001", "start" => start, "values" => values }
        File.write(path, JSON.generate("calendar" => calendar, "series" => [entry]))
        error = assert_raises(Study::Error, name) { Study.run(**files, subset_path: path) }

        assert_equal "#{path}: the values of 10001 do not cover the trading dates from #{start} to #{calendar.last}",
                     error.message
      end
      failing = ->(*_series, **_options) { raise "boom" }
      error = Foresight.stub(:backtest, failing) { assert_raises(Study::Error) { Study.run(**files) } }

      assert_equal "#{synthetic_ids.first} under distribution quantiles: boom (RuntimeError)", error.message
      assert_equal "kept\n", File.read(files[:output_path])
      assert_empty Dir.children(dir).grep(/\.tmp\z/)
    end
  end

  def test_the_reduced_results_render_into_copies_of_both_documents_identically_twice
    with_study_files do |files, subset|
      Study.run(**files)
      copies = document_copies(File.dirname(files[:output_path]))
      regions = Render.run(results_path: files[:output_path], document_paths: copies)
      rendered = copies.transform_values { |copy| File.binread(copy) }
      Render.run(results_path: files[:output_path], document_paths: copies)

      assert_equal rendered, copies.transform_values { |copy| File.binread(copy) }
      assert_equal File.binread(Render::DOCUMENTS[:methodology]), rendered[:methodology]
      assert_equal Render::REGIONS.sort, regions.keys.sort
      assert_equal Render::REGIONS.sort, rendered.values.join.scan(/^<!-- generated:([a-z-]+) -->$/).flatten.sort
      regions.each do |name, body|
        refute_empty body, name
        assert_includes rendered.values.join, "<!-- generated:#{name} -->\n#{body}\n<!-- /generated:#{name} -->"
      end
      rendered.each_value { |text| assert_equal text, Render.fill(text, regions) }
      short = subset["series"].find { |entry| entry["stock_code"] == SHORT_CODE }
      message = assert_raises(Foresight::InputError) do
        Foresight.backtest(short["values"], strategy: :conformal, **backtest_settings)
      end.message

      assert_includes regions["summary-real"], "Series set aside because they had no non-zero observation: 1."
      assert_includes regions["summary-real"], "- `#{SHORT_CODE}` under the conformal quantiles: #{message}"
      assert_includes regions["summary-real"], "| smooth | 1 |"
      assert_includes regions["summary-real"], " undefined |"
      assert_includes regions["summary-real"], "] (2 series) |"
      refute_includes regions["summary-synthetic"], " series) |"
      assert_includes regions["configuration"], "| origins | 2 |\n"
      assert_includes regions["configuration"], "| calibration windows | 2 |\n"
      assert_equal PROCESSES.map { |process| "| #{process["name"]} |" },
                   regions["processes"].lines.drop(2).map { |line| line[/\A\| [a-z-]+ \|/] }
    end
  end

  def test_a_document_with_a_missing_duplicated_unknown_or_disordered_marker_fails_the_render_and_stays_unchanged
    with_study_files do |files|
      Study.run(**files)
      copies = document_copies(File.dirname(files[:output_path]))
      Render.run(results_path: files[:output_path], document_paths: copies)
      validation = File.binread(copies[:validation])
      start = "<!-- generated:parity -->"
      finish = "<!-- /generated:parity -->"
      parity = /^#{Regexp.escape(start)}\n.*?^#{Regexp.escape(finish)}\n/m
      methodology = File.binread(copies[:methodology])
      defaults = methodology[%r{^<!-- generated:defaults -->\n.*?^<!-- /generated:defaults -->$}m]
      broken = {
        "missing end marker" => validation.sub("#{finish}\n", ""),
        "missing start marker" => validation.sub("#{start}\n", ""),
        "duplicated region" => validation.sub(finish, "#{finish}\n\n#{start}\n#{finish}"),
        "duplicated end marker" => validation.sub(finish, "#{finish}\n#{finish}"),
        "end marker before the start marker" => validation.sub(start, "swap").sub(finish, start).sub("swap", finish),
        "unknown region" => validation.gsub("generated:parity", "generated:extra"),
        "region absent from both documents" => validation.sub(parity, ""),
        "region present in both documents" => "#{validation}\n#{defaults}\n"
      }

      broken.each do |about, text|
        File.write(copies[:validation], text)
        before = copies.transform_values { |copy| File.binread(copy) }
        error = assert_raises(Render::Error, about) do
          Render.run(results_path: files[:output_path], document_paths: copies)
        end

        assert_match(/\b(?:parity|extra|defaults)\b/, error.message, about)
        assert_equal before, copies.transform_values { |copy| File.binread(copy) }, about
        assert_empty Dir.children(File.dirname(files[:output_path])).grep(/\.tmp\z/), about
      end
    end
  end

  private

  def document_copies(dir)
    Render::DOCUMENTS.to_h do |name, path|
      copy = File.join(dir, File.basename(path))
      FileUtils.cp(path, copy)
      [name, copy]
    end
  end

  def each_seed(count)
    rng = Random.new(SEED)
    count.times do
      seed = rng.rand(2**32)
      yield seed, Random.new(seed)
    end
  end

  def random_document(random)
    random_hash(random, 1)
  end

  def random_hash(random, depth)
    KEYS.sample(random.rand(1..5), random: random).to_h { |key| [key, random_node(random, depth)] }
  end

  def random_node(random, depth)
    case depth < 4 ? random.rand(7) : random.rand(4)
    when 0 then nil
    when 1 then random_integer(random)
    when 2 then random_float(random)
    when 3 then STRINGS.sample(random: random)
    when 4 then Array.new(random.rand(0..4)) { random_node(random, depth + 1) }
    else random_hash(random, depth + 1)
    end
  end

  def random_integer(random)
    case random.rand(3)
    when 0 then INTEGERS.sample(random: random)
    when 1 then random.rand(-1_000_000..1_000_000)
    else random.rand(2**64)
    end
  end

  def random_float(random)
    case random.rand(5)
    when 0 then FLOATS.sample(random: random)
    when 1 then random.rand * Float::MIN
    when 2 then random.rand(-1e6..1e6)
    when 3 then random.rand * 10.0**random.rand(-320..308)
    else random.rand
    end
  end

  def leaves_of(node)
    case node
    when Hash then node.values.flat_map { |value| leaves_of(value) }
    when Array then node.flat_map { |value| leaves_of(value) }
    else [node]
    end
  end

  def depth_of(node)
    children = Hash === node ? node.values : node
    return 0 unless Array === children

    1 + children.map { |child| depth_of(child) }.max.to_i
  end

  def typed(node)
    case node
    when Hash then [Hash, node.map { |key, value| [typed(key), typed(value)] }]
    when Array then [Array, node.map { |value| typed(value) }]
    when Float then [Float, node.to_s]
    else [node.class, node]
    end
  end

  def random_records(random, levels)
    count = case random.rand(6)
            when 0 then random.rand(0..1)
            when 1 then 2
            else random.rand(2..30)
            end
    Array.new(count) { |index| random_record(random, levels, index) }
  end

  def random_record(random, levels, index)
    origins = random.rand(5).zero? ? 0 : random.rand(1..6)
    held_out = origins * random.rand(1..7)
    record = { "id" => "series/#{index}", "origins" => origins, "held_out" => held_out }
    STRATEGIES.each do |strategy|
      entries = levels.shuffle(random: random).map do |level|
        { "level" => level, "covered" => random.rand(0..held_out), "lead_time_hits" => random.rand(0..origins),
          "scaled_pinball" => random_loss(random, origins) }
      end
      record[strategy] = { "levels" => entries }
    end
    record
  end

  def random_loss(random, origins)
    return if origins.zero? || random.rand < 0.15

    random.rand * [0.01, 1.0, 100.0].sample(random: random)
  end

  def oracle_intervals(records, levels, resamples, seed)
    samples = []
    if records.size >= 2
      rng = Random.new(seed)
      samples = Array.new(resamples) do
        draw = Array.new(records.size) { records[rng.rand(records.size)] }
        oracle_statistics(draw, levels)
      end
    end
    named = STRATEGIES.to_h { |strategy| [strategy, STATISTICS] }.merge("difference" => DIFFERENCES)
    named.to_h do |name, statistics|
      by_level = levels.to_h do |level|
        intervals = statistics.to_h do |statistic|
          ["#{statistic}_interval", percentile_interval(samples.map { |sample| sample[name][level][statistic] })]
        end
        [level, intervals]
      end
      [name, by_level]
    end
  end

  def percentile_interval(values)
    return if values.empty? || values.any?(&:nil?)

    sorted = values.sort
    count = sorted.size
    [sorted[(25 * count + 999) / 1000 - 1], sorted[(975 * count + 999) / 1000 - 1]]
  end

  def oracle_statistics(records, levels)
    held_out, origins = members_sum(records, %w[held_out origins])
    pooled = STRATEGIES.to_h do |strategy|
      by_level = levels.to_h do |level|
        entries = records.map { |record| record[strategy]["levels"].find { |entry| entry["level"] == level } }
        losses = entries.map { |entry| entry["scaled_pinball"] }.compact
        [level, { "coverage" => share(entries.sum { |entry| entry["covered"] }, held_out),
                  "lead_time_coverage" => share(entries.sum { |entry| entry["lead_time_hits"] }, origins),
                  "scaled_pinball" => sequential_mean(losses) }]
      end
      [strategy, by_level]
    end
    paired = levels.to_h do |level|
      [level, oracle_differences(pooled["distribution"][level], pooled["conformal"][level], level)]
    end
    pooled.merge("difference" => paired)
  end

  def oracle_differences(distribution, conformal, level)
    {
      "coverage_error" => error_gap(distribution["coverage"], conformal["coverage"], level),
      "lead_time_coverage_error" => error_gap(distribution["lead_time_coverage"], conformal["lead_time_coverage"],
                                              level),
      "scaled_pinball" => gap(distribution["scaled_pinball"], conformal["scaled_pinball"]),
      "coverage" => gap(distribution["coverage"], conformal["coverage"]),
      "lead_time_coverage" => gap(distribution["lead_time_coverage"], conformal["lead_time_coverage"])
    }
  end

  def share(count, total)
    Rational(count, total).to_f unless total.zero?
  end

  def sequential_mean(values)
    values.inject { |sum, value| sum + value } / values.size unless values.empty?
  end

  def gap(distribution, conformal)
    distribution - conformal if distribution && conformal
  end

  def error_gap(distribution, conformal, level)
    (distribution - level).abs - (conformal - level).abs if distribution && conformal
  end

  def flat_intervals(intervals)
    pairs = intervals.flat_map do |name, by_level|
      by_level.flat_map { |level, entries| entries.map { |key, interval| ["#{name} #{level} #{key}", interval] } }
    end
    pairs.to_h
  end

  def members_sum(records, names)
    names.map { |name| records.sum { |record| record[name] } }
  end

  def with_study_files(config = REDUCED_CONFIG)
    Dir.mktmpdir do |dir|
      files = { config_path: File.join(dir, "study_config.json"), subset_path: File.join(dir, "subset.json"),
                output_path: File.join(dir, "study_results.json") }
      subset = subset_document
      File.write(files[:config_path], "#{JSON.pretty_generate(config)}\n")
      File.write(files[:subset_path], "#{JSON.pretty_generate(subset)}\n")
      yield files, subset
    end
  end

  def subset_document
    random = Random.new(SEED)
    calendar = trading_calendar
    series = SUBSET_SHAPES.map do |code, start, shape|
      { "stock_code" => code, "start" => calendar[start],
        "values" => shaped_values(random, shape, calendar.size - start) }
    end
    { "calendar" => calendar, "series" => series }
  end

  def trading_calendar
    first = Date.new(2011, 1, 3)
    Array.new(CALENDAR_DATES * 2) { |index| first + index }.reject(&:sunday?).first(CALENDAR_DATES).map(&:to_s)
  end

  def shaped_values(random, shape, length)
    case shape
    when :zero then Array.new(length, 0)
    when :smooth then Array.new(length) { random.rand(40..60) }
    else
      values = Array.new(length) { random.rand < 0.3 ? random.rand(1..2) : 0 }
      values[0] = 1
      values
    end
  end

  def backtest_settings
    settings = %w[horizon origins step levels paths windows].to_h { |name| [name.to_sym, SETTINGS[name]] }
    settings.merge(seed: SETTINGS["backtest_seed"])
  end

  def synthetic_ids
    PROCESSES.flat_map { |process| process_seeds(process).map { |seed| "#{process["name"]}/#{seed}" } }
  end

  def process_seeds(process)
    Array.new(process["series"]) { |index| process["first_seed"] + index }
  end

  def committed_results
    JSON.parse(File.read(RESULTS_FILE))
  end

  def committed_config
    JSON.parse(File.read(CONFIG_FILE))
  end

  def subset_series
    JSON.parse(File.read(SUBSET_FILE))["series"]
  end

  def field(section, name)
    section["series"].map { |record| record[name] }
  end

  def assert_series_records(section, about, config)
    section["series"].each do |record|
      where = "#{about} #{record["id"]}"

      assert_equal SERIES_KEYS, record.keys, where
      assert_includes DEMAND_CLASSES, record["demand_class"], where
      assert_includes 0..config["origins"], record["origins"], where
      assert_equal typed([config["horizon"] * record["origins"], record["held_out"]]),
                   typed([record["held_out"], record["zero_held_out"] + record["nonzero_held_out"]]), where
      STRATEGIES.each do |strategy|
        assert_equal STRATEGY_KEYS, record[strategy].keys, where
        assert_equal config["levels"], record[strategy]["levels"].map { |entry| entry["level"] }, where
        record[strategy]["levels"].each do |entry|
          at = "#{where} #{strategy} #{entry["level"]}"

          assert_equal SERIES_LEVEL_KEYS, entry.keys, at
          assert_equal [Integer, Integer], entry.values_at("covered", "lead_time_hits").map(&:class), at
          assert_includes 0..record["held_out"], entry["covered"], at
          assert_includes 0..record["origins"], entry["lead_time_hits"], at
          assert_same_value share(entry["covered"], record["held_out"]), entry["coverage"], at
          assert_same_value share(entry["lead_time_hits"], record["origins"]), entry["lead_time_coverage"], at
          assert_parts entry.values_at(*PARTS), at
        end
      end
    end
  end

  def assert_process_records(synthetic, config)
    levels = config["levels"]
    processes = config["processes"]

    assert_equal processes.map { |process| process["name"] }, synthetic["processes"].map { |record| record["name"] }
    synthetic["processes"].zip(processes).each do |record, process|
      members = synthetic["series"].select { |series| series["process"] == process["name"] }
      pooled = oracle_statistics(members, levels)
      truths = Truth.quantiles(process, horizon: config["horizon"], levels: levels)
      about = process["name"]

      assert_equal PROCESS_KEYS, record.keys, about
      assert_equal typed([members.size, *members_sum(members, %w[origins held_out])]),
                   typed(record.values_at("series", "origins", "held_out")), about
      assert_equal levels, record["levels"].map { |entry| entry["level"] }, about
      record["levels"].each do |entry|
        level = entry["level"]
        truth = entry["truth"]
        where = "#{about} #{level}"

        assert_equal %w[level distribution conformal truth], entry.keys, where
        STRATEGIES.each do |strategy|
          assert_equal typed(pooled[strategy][level].slice("coverage", "lead_time_coverage")),
                       typed(entry[strategy]), where
        end
        assert_equal TRUTH_KEYS, truth.keys, where
        assert_equal typed([truths[level].step_quantile.to_f, truths[level].total_quantile.to_f,
                            truths[level].step_probability&.to_f, truths[level].total_probability&.to_f]),
                     typed(truth.values_at("step_quantile", "total_quantile", "step_probability",
                                           "total_probability")), where
        %w[coverage lead_time_coverage].each do |name|
          assert_instance_of Float, truth[name], "#{where} #{name}"
          assert_includes 0.0..1.0, truth[name], "#{where} #{name}"
        end
      end
    end
  end

  def assert_class_records(section, offset, about, config)
    levels = config["levels"]
    bootstrap = config["bootstrap"]
    section["classes"].each_with_index.map do |record, index|
      demand_class = DEMAND_CLASSES[index]
      members = section["series"].select { |series| series["demand_class"] == demand_class }
      seed = bootstrap["seed"] + offset + index
      intervals = Bootstrap.intervals(members, levels: levels, resamples: bootstrap["resamples"], seed: seed)
      where = "#{about} #{demand_class}"

      assert_equal CLASS_KEYS, record.keys, where
      assert_equal typed([demand_class, members.size, seed]),
                   typed(record.values_at("demand_class", "series", "bootstrap_seed")), where
      assert_equal typed(members_sum(members, COUNTS)), typed(record.values_at(*COUNTS)), where
      assert_equal members.sum { |member| config["origins"] - member["origins"] }, record["excluded_origins"], where
      assert_kind_of Integer, record["zero_scale_origins"], where
      STRATEGIES.each do |strategy|
        assert_class_strategy(record, members, intervals, strategy, where, levels)
      end
      assert_class_differences(record, members, intervals, where, levels)
      members.size
    end
  end

  def assert_class_strategy(record, members, intervals, strategy, where, levels)
    summary = record[strategy]
    held_out, origins = members_sum(members, %w[held_out origins])

    assert_equal STRATEGY_KEYS, summary.keys, where
    MEANS.each do |name|
      assert_same_value sequential_mean(members.filter_map { |member| member[strategy][name] }), summary[name],
                        "#{where} #{strategy} #{name}"
    end
    assert_equal levels, summary["levels"].map { |entry| entry["level"] }, where
    summary["levels"].each do |entry|
      level = entry["level"]
      at = "#{where} #{strategy} #{level}"
      pooled = members.map { |member| member[strategy]["levels"].find { |candidate| candidate["level"] == level } }

      assert_equal CLASS_LEVEL_KEYS, entry.keys, at
      assert_same_value share(pooled.sum { |candidate| candidate["covered"] }, held_out), entry["coverage"], at
      assert_same_value share(pooled.sum { |candidate| candidate["lead_time_hits"] }, origins),
                        entry["lead_time_coverage"], at
      PARTS.each do |name|
        assert_same_value sequential_mean(pooled.filter_map { |candidate| candidate[name] }), entry[name],
                          "#{at} #{name}"
      end
      assert_parts entry.values_at(*PARTS), at
      STATISTICS.each do |statistic|
        assert_interval entry["#{statistic}_interval"], intervals[strategy][level]["#{statistic}_interval"],
                        members.size, pooled.all? { |candidate| candidate[statistic] }, "#{at} #{statistic}"
      end
    end
  end

  def assert_class_differences(record, members, intervals, where, levels)
    record["difference"]["levels"].each_with_index do |entry, position|
      level = levels[position]
      distribution, conformal = STRATEGIES.map { |strategy| record[strategy]["levels"][position] }
      expected = oracle_differences(distribution, conformal, level)
      at = "#{where} difference #{level}"

      assert_equal DIFFERENCE_KEYS, entry.keys, at
      assert_equal level, entry["level"], at
      DIFFERENCES.each do |name|
        statistic = name.delete_suffix("_error")
        defined = members.all? do |member|
          STRATEGIES.all? do |strategy|
            member[strategy]["levels"].find { |candidate| candidate["level"] == level }[statistic]
          end
        end

        assert_same_value expected[name], entry[name], "#{at} #{name}"
        assert_interval entry["#{name}_interval"], intervals["difference"][level]["#{name}_interval"], members.size,
                        defined, "#{at} #{name}"
      end
    end
  end

  def assert_interval(interval, expected, count, defined, about)
    assert_same_value expected, interval, about
    if count < 2
      assert_nil interval, about
    elsif defined
      refute_nil interval, about
      assert_equal [Float, Float], interval.map(&:class), about
      assert_operator interval.first, :<=, interval.last, about
    end
  end

  def assert_same_value(expected, actual, about = nil)
    if expected.nil?
      assert_nil actual, about
    else
      assert_equal typed([expected]), typed([actual]), about
    end
  end

  def assert_parts(parts, about)
    whole, zero, nonzero = parts
    if whole.nil?
      assert_equal [nil, nil, nil], parts, about
    else
      assert_equal [Float, Float, Float], parts.map(&:class), about
      assert_operator (zero.to_r + nonzero.to_r - whole.to_r).abs, :<=, whole.to_r * TOLERANCE, about
    end
  end
end
