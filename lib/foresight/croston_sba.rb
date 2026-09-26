# frozen_string_literal: true

module Foresight
  class CrostonSBA
    def self.minimum_history(_options)
      1
    end

    def initialize(values, options)
      @factor = 1 - options[:alpha].to_f / 2.0
      @classic = CrostonClassic.new(values, options)
    end

    def forecast(horizon)
      @classic.forecast(horizon).map { |value| @factor * value }
    end
  end
end
