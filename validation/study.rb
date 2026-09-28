# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "foresight"
require_relative "bootstrap"
require_relative "truth"

module Study
  ROOT = File.expand_path("..", __dir__)
  CONFIG_FILE = File.join(ROOT, "validation", "study_config.json")
  SUBSET_FILE = File.join(ROOT, "data", "online_retail_ii_subset.json")
  RESULTS_FILE = File.join(ROOT, "validation", "study_results.json")
  SETTINGS = %w[horizon origins step levels paths windows].freeze
  STRATEGIES = Bootstrap::STRATEGIES
  DEMAND_CLASSES = Foresight::EvaluationReport::DEMAND_CLASSES
  SMOOTH_MODELS = %i[naive seasonal_naive ses].freeze
  INTERMITTENT_MODELS = %i[croston_classic croston_sba tsb].freeze

  class Error < StandardError
  end

  Series = Struct.new(:id, :process, :seed, :stock_code, :values, keyword_init: true)
  Outcome = Struct.new(:series, :demand_class, :backtests, :record, keyword_init: true)
  Evaluation = Struct.new(:outcomes, :excluded, :all_zero, keyword_init: true)

  class << self
    def run(config_path: CONFIG_FILE, subset_path: SUBSET_FILE, output_path: RESULTS_FILE)
      config = read_json(config_path)
      real = load_subset(subset_path)
      document = results(config, real, Digest::SHA256.file(subset_path).hexdigest)
      write(document, output_path)
      document
    end

    def load_subset(path)
      subset = read_json(path)
      calendar = subset.fetch("calendar")
      subset.fetch("series").map do |entry|
        code = entry.fetch("stock_code")
        start = calendar.index(entry.fetch("start"))
        values = entry.fetch("values")
        unless start && values.size == calendar.size - start
          raise Error, "#{path}: the values of #{code} do not cover the trading dates from #{entry["start"]} " \
                       "to #{calendar.last}"
        end

        Series.new(id: code, stock_code: code, values: values)
      end
    rescue KeyError => e
      raise Error, "cannot read #{path}: #{e.message}"
    end

    private

    def read_json(path)
      JSON.parse(File.read(path))
    rescue SystemCallError, JSON::ParserError => e
      raise Error, "cannot read #{path}: #{e.message}"
    end

    def results(config, real, subset_sha256)
      settings = settings(config)
      bootstrap = config.fetch("bootstrap")
      synthetic = evaluate(synthetic_series(config), settings)
      seeded = config["processes"].map { |process| process.merge("seeds" => seeds(process)) }
      processes = process_records(config, synthetic.outcomes, settings)
      {
        "foresight_version" => Foresight::VERSION, "ruby_version" => RUBY_VERSION, "ruby_platform" => RUBY_PLATFORM,
        "real_subset_sha256" => subset_sha256,
        "config" => config.merge("processes" => seeded),
        "synthetic" => section(synthetic, settings, bootstrap, 0).merge("processes" => processes),
        "real" => section(evaluate(real, settings), settings, bootstrap, DEMAND_CLASSES.size)
      }
    end

    def settings(config)
      SETTINGS.to_h { |name| [name.to_sym, config.fetch(name)] }.merge(seed: config.fetch("backtest_seed"))
    end

    def synthetic_series(config)
      config["processes"].flat_map do |process|
        seeds(process).map do |seed|
          Series.new(id: "#{process["name"]}/#{seed}", process: process, seed: seed, values: generate(process, seed))
        end
      end
    end

    def seeds(process)
      Array.new(process["series"]) { |index| process["first_seed"] + index }
    end

    def generate(process, seed)
      rng = Random.new(seed)
      if process["kind"] == "gaussian"
        Array.new(process["length"]) { gaussian(rng, process["mean"], process["sd"]) }
      else
        Array.new(process["length"]) { bernoulli(rng, process["occurrence"], process["sizes"]) }
      end
    end

    def gaussian(rng, mean, sd)
      radius = Math.sqrt(-2 * Math.log(1 - rng.rand))
      angle = 2 * Math::PI * rng.rand
      [0.0, mean + sd * radius * Math.cos(angle)].max
    end

    def bernoulli(rng, occurrence, sizes)
      return 0 unless rng.rand < occurrence

      pick = rng.rand(sizes.sum { |_size, weight| weight })
      sizes.each do |size, weight|
        return size if pick < weight

        pick -= weight
      end
    end

    def evaluate(series, settings)
      zeros, candidates = series.partition { |candidate| candidate.values.all?(&:zero?) }
      evaluated = candidates.map { |candidate| outcome(candidate, settings) }
      outcomes, excluded = evaluated.partition { |result| Outcome === result }
      Evaluation.new(outcomes: outcomes, excluded: excluded, all_zero: zeros.size)
    end

    def outcome(series, settings)
      backtests = {}
      STRATEGIES.each do |strategy|
        backtests[strategy] = backtest_under(series, strategy, settings)
      rescue Foresight::InputError => e
        return { "id" => series.id, "strategy" => strategy, "message" => e.message }
      end
      backtests.each_value { |backtest| check_family(series, backtest) } if series.process
      demand_class = Foresight.classify(series.values).demand_class
      Outcome.new(series: series, demand_class: demand_class, backtests: backtests,
                  record: series_record(series, demand_class, backtests, settings[:levels]))
    end

    def backtest_under(series, strategy, settings)
      Foresight.backtest(series.values, strategy: strategy.to_sym, **settings)
    rescue Foresight::InputError
      raise
    rescue StandardError => e
      raise Error, "#{series.id} under #{strategy} quantiles: #{e.message} (#{e.class})"
    end

    def check_family(series, backtest)
      smooth = series.process["kind"] == "gaussian"
      unexpected = smooth ? INTERMITTENT_MODELS : SMOOTH_MODELS
      origin = backtest.origins.find { |candidate| unexpected.include?(candidate.model) }
      return unless origin

      raise Error, "#{series.process["name"]} seed #{series.seed}, origin at position #{origin.start}: automatic " \
                   "selection chose #{origin.model}, #{smooth ? "an intermittent" : "a smooth"} model"
    end

    def series_record(series, demand_class, backtests, levels)
      backtest = backtests["distribution"]
      {
        "id" => series.id, "process" => series.process&.fetch("name"), "seed" => series.seed,
        "stock_code" => series.stock_code, "demand_class" => demand_class.to_s,
        "origins" => backtest.origins.size, "held_out" => backtest.held_out,
        "zero_held_out" => backtest.zero_held_out, "nonzero_held_out" => backtest.nonzero_held_out,
        "distribution" => series_strategy_record(backtests["distribution"], levels),
        "conformal" => series_strategy_record(backtests["conformal"], levels)
      }
    end

    def series_strategy_record(backtest, levels)
      strategy_record(backtest, levels) do |level|
        { "covered" => backtest.covered[level], "lead_time_hits" => backtest.lead_time_hits[level] }
      end
    end

    def strategy_record(source, levels)
      {
        "mae" => source.mae, "rmse" => source.rmse, "mase" => source.mase,
        "levels" => levels.map { |level| level_record(source, level).merge(yield(level)) }
      }
    end

    def level_record(source, level)
      {
        "level" => level, "scaled_pinball" => source.scaled_pinball[level],
        "scaled_pinball_zero" => source.scaled_pinball_zero[level],
        "scaled_pinball_nonzero" => source.scaled_pinball_nonzero[level],
        "coverage" => source.coverage[level], "lead_time_coverage" => source.lead_time_coverage[level]
      }
    end

    def section(evaluation, settings, bootstrap, offset)
      {
        "series" => evaluation.outcomes.map(&:record), "excluded" => evaluation.excluded,
        "excluded_all_zero" => evaluation.all_zero,
        "classes" => class_records(evaluation.outcomes, settings, bootstrap, offset)
      }
    end

    def class_records(outcomes, settings, bootstrap, offset)
      reports = STRATEGIES.to_h { |strategy| [strategy, evaluation_report(outcomes, strategy, settings)] }
      DEMAND_CLASSES.each_with_index.map do |demand_class, index|
        records = outcomes.select { |outcome| outcome.demand_class == demand_class }.map(&:record)
        summaries = reports.transform_values { |report| report.classes[demand_class] }
        class_record(demand_class, records, summaries, settings[:levels], bootstrap.fetch("resamples"),
                     bootstrap.fetch("seed") + offset + index)
      end
    end

    def evaluation_report(outcomes, strategy, settings)
      entries = outcomes.each_with_index.map do |outcome, index|
        Foresight::SeriesEntry.new(index: index, demand_class: outcome.demand_class,
                                   backtest: outcome.backtests[strategy])
      end
      Foresight::EvaluationReport.aggregate(entries, horizon: settings[:horizon], levels: settings[:levels])
    end

    def class_record(demand_class, records, summaries, levels, resamples, seed)
      intervals = Bootstrap.intervals(records, levels: levels, resamples: resamples, seed: seed)
      strategies = STRATEGIES.to_h do |strategy|
        [strategy, strategy_record(summaries[strategy], levels) { |level| intervals[strategy][level] }]
      end
      summary = summaries["distribution"]
      {
        "demand_class" => demand_class.to_s, "series" => summary.series_count,
        "origins" => records.sum { |record| record["origins"] }, "held_out" => summary.held_out,
        "zero_held_out" => summary.zero_held_out, "nonzero_held_out" => summary.nonzero_held_out,
        "excluded_origins" => summary.excluded_origins, "zero_scale_origins" => summary.zero_scale_origins,
        "bootstrap_seed" => seed, "distribution" => strategies["distribution"], "conformal" => strategies["conformal"],
        "difference" => difference_record(strategies, intervals["difference"], levels)
      }
    end

    def difference_record(strategies, intervals, levels)
      differences = levels.each_with_index.map do |level, index|
        distribution, conformal = STRATEGIES.map { |strategy| strategies[strategy]["levels"][index] }
        point = Bootstrap.differences(distribution, conformal, level)
        point.each_with_object({ "level" => level }) do |(name, value), record|
          record[name] = value
          record["#{name}_interval"] = intervals[level]["#{name}_interval"]
        end
      end
      { "levels" => differences }
    end

    def process_records(config, outcomes, settings)
      levels = settings[:levels]
      config["processes"].map do |process|
        members = outcomes.select { |outcome| outcome.series.process["name"] == process["name"] }
        records = members.map(&:record)
        pooled = Bootstrap.statistics(records, levels)
        truths = Truth.quantiles(process, horizon: settings[:horizon], levels: levels)
        origins = records.sum { |record| record["origins"] }
        held_out = records.sum { |record| record["held_out"] }
        {
          "name" => process["name"], "series" => members.size, "origins" => origins, "held_out" => held_out,
          "levels" => levels.map do |level|
            {
              "level" => level,
              "distribution" => pooled["distribution"][level].slice("coverage", "lead_time_coverage"),
              "conformal" => pooled["conformal"][level].slice("coverage", "lead_time_coverage"),
              "truth" => truth_record(members, truths[level], settings[:horizon], origins, held_out)
            }
          end
        }
      end
    end

    def truth_record(members, truth, horizon, origins, held_out)
      windows = members.flat_map do |outcome|
        outcome.backtests["distribution"].origins.map { |origin| outcome.series.values[origin.start, horizon] }
      end
      covered = windows.sum { |window| window.count { |value| value <= truth.step_quantile } }
      hits = windows.count { |window| window.sum <= truth.total_quantile }
      {
        "coverage" => ratio(covered, held_out), "lead_time_coverage" => ratio(hits, origins),
        "step_quantile" => truth.step_quantile.to_f, "total_quantile" => truth.total_quantile.to_f,
        "step_probability" => truth.step_probability&.to_f, "total_probability" => truth.total_probability&.to_f
      }
    end

    def ratio(count, total)
      count.fdiv(total) unless total.zero?
    end

    def write(results, path)
      temporary = "#{path}.tmp"
      File.write(temporary, "#{JSON.pretty_generate(results)}\n")
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary)
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    Study.run
  rescue Study::Error => e
    abort e.message
  end
end
