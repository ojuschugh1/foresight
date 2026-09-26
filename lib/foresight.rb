# frozen_string_literal: true

require "date"
require_relative "foresight/version"
require_relative "foresight/input_error"

module Foresight
  DEFAULT_COUNT   = 10
  DEFAULT_LEVELS  = [0.5, 0.8, 0.9, 0.95].freeze
  DEFAULT_SEED    = 0
  DEFAULT_PATHS   = 10_000
  DEFAULT_WINDOWS = 2
end
