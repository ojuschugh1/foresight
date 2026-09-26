# frozen_string_literal: true

module Foresight
  class SES
    attr_reader :alpha

    def self.minimum_history(_options)
      1
    end

    def initialize(values, _options)
      @alpha = Smoothing.golden_section(values, 0.01, 0.99)
      @forecast = Smoothing.run(values, alpha).first
    end

    def forecast(horizon)
      Array.new(horizon, @forecast)
    end
  end
end
