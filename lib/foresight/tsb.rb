# frozen_string_literal: true

module Foresight
  class TSB
    def self.minimum_history(_options)
      1
    end

    def initialize(values, options)
      @forecast = 0.0
      sizes = values.reject(&:zero?)
      return if sizes.empty?

      occurrences = values.map { |value| value.zero? ? 0.0 : 1.0 }
      occurrence = Smoothing.run(occurrences, options[:alpha_p].to_f).first
      size = Smoothing.run(sizes, options[:alpha_d].to_f).first
      @forecast = occurrence * size
    end

    def forecast(horizon)
      Array.new(horizon, @forecast)
    end
  end
end
