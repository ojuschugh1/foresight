# frozen_string_literal: true

module Foresight
  class CrostonClassic
    attr_reader :interval, :probability, :sizes

    def self.minimum_history(_options)
      1
    end

    def initialize(values, options)
      @forecast = 0.0
      @probability = 0.0
      sizes = values.reject(&:zero?)
      @sizes = sizes.sort
      return if sizes.empty?

      alpha = options[:alpha].to_f
      positions = (1..values.size).reject { |position| values[position - 1].zero? }
      intervals = [0, *positions].each_cons(2).map { |earlier, later| (later - earlier).to_f }
      size = Smoothing.run(sizes, alpha).first
      @interval = Smoothing.run(intervals, alpha).first
      @forecast = interval.zero? ? size : size / interval
      @probability = [1.0, 1.0 / interval].min
    end

    def forecast(horizon)
      Array.new(horizon, @forecast)
    end
  end
end
