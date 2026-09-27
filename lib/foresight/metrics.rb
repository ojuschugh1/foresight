# frozen_string_literal: true

module Foresight
  module Metrics
    class << self
      def scale(history)
        total = history.each_cons(2).inject(0.0) { |sum, (earlier, later)| sum + (later - earlier).abs }
        total / (history.size - 1)
      end

      def mae(actual, forecast)
        total = actual.zip(forecast).inject(0.0) { |sum, (value, predicted)| sum + (value - predicted).abs }
        total / actual.size
      end

      def rmse(actual, forecast)
        total = actual.zip(forecast).inject(0.0) do |sum, (value, predicted)|
          error = value - predicted
          sum + error * error
        end
        Math.sqrt(total / actual.size)
      end

      def pinball(level, quantile, actual)
        level = level.to_f
        actual >= quantile ? level * (actual - quantile) : (1 - level) * (quantile - actual)
      end
    end
  end
end
