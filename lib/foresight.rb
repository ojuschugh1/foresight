# frozen_string_literal: true

require "date"
require_relative "foresight/version"
require_relative "foresight/input_error"
require_relative "foresight/frequency"
require_relative "foresight/series"
require_relative "foresight/classifier"

module Foresight
  DEFAULT_COUNT   = 10
  DEFAULT_LEVELS  = [0.5, 0.8, 0.9, 0.95].freeze
  DEFAULT_SEED    = 0
  DEFAULT_PATHS   = 10_000
  DEFAULT_WINDOWS = 2

  def self.classify(series)
    Classifier.call(Series.parse(series, keys_required: false).exact)
  end
end
