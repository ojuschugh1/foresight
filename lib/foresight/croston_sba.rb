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

    def probability
      return 0.0 if sizes.empty?

      # Scaling the occurrence probability by the SBA factor is Foresight's own choice, see docs/methodology.md
      [1.0, @factor / @classic.interval].min
    end

    def sizes
      @classic.sizes
    end
  end
end
