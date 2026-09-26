# frozen_string_literal: true

module Foresight
  class CrostonClassic
    def self.minimum_history(_options)
      1
    end

    def initialize(values, options)
      @forecast = 0.0
      sizes = values.reject(&:zero?)
      return if sizes.empty?

      alpha = options[:alpha].to_f
      positions = (1..values.size).reject { |position| values[position - 1].zero? }
      intervals = [0, *positions].each_cons(2).map { |earlier, later| (later - earlier).to_f }
      size = Smoothing.run(sizes, alpha).first
      interval = Smoothing.run(intervals, alpha).first
      @forecast = interval.zero? ? size : size / interval
    end

    def forecast(horizon)
      Array.new(horizon, @forecast)
    end
  end
end
