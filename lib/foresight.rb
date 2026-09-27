# frozen_string_literal: true

require "date"
require_relative "foresight/version"
require_relative "foresight/input_error"
require_relative "foresight/frequency"
require_relative "foresight/series"
require_relative "foresight/options"
require_relative "foresight/classifier"
require_relative "foresight/selector"
require_relative "foresight/normal"
require_relative "foresight/empirical_quantile"
require_relative "foresight/smoothing"
require_relative "foresight/naive"
require_relative "foresight/seasonal_naive"
require_relative "foresight/ses"
require_relative "foresight/croston_classic"
require_relative "foresight/croston_sba"
require_relative "foresight/tsb"
require_relative "foresight/gaussian_strategy"
require_relative "foresight/compound_strategy"
require_relative "foresight/simulator"
require_relative "foresight/conformal_strategy"
require_relative "foresight/forecaster"
require_relative "foresight/result"
require_relative "foresight/metrics"
require_relative "foresight/backtester"
require_relative "foresight/evaluation_report"

module Foresight
  DEFAULT_COUNT   = 10
  DEFAULT_LEVELS  = [0.5, 0.8, 0.9, 0.95].freeze
  DEFAULT_SEED    = 0
  DEFAULT_PATHS   = 10_000
  DEFAULT_WINDOWS = 2
  MODELS = { naive: Naive, seasonal_naive: SeasonalNaive, ses: SES,
             croston_classic: CrostonClassic, croston_sba: CrostonSBA, tsb: TSB }.freeze

  def self.forecast(series, **options)
    forecaster = Forecaster.new(Options.forecast(options))
    forecaster.call(Series.parse(series, keys_required: true))
  end

  def self.classify(series)
    Classifier.call(Series.parse(series, keys_required: false).exact)
  end

  def self.backtest(series, **options)
    Backtester.new(**options).run(series)
  end

  def self.evaluate(collection, **options)
    Backtester.new(**options).evaluate(collection)
  end
end
