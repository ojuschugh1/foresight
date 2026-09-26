# frozen_string_literal: true

module Foresight
  class Naive
    def self.minimum_history(_options)
      1
    end

    def initialize(values, _options)
      @forecast = values.last
    end

    def forecast(horizon)
      Array.new(horizon, @forecast)
    end
  end
end
