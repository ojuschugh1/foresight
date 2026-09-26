# frozen_string_literal: true

module Foresight
  # Follows ses_sse, ses_forecast and golden_section_ses in statsforecast src/ses.cpp, operation by operation
  module Smoothing
    class << self
      def sse(values, alpha)
        return 0.0 if values.size < 2

        complement = 1.0 - alpha
        forecast = values[0]
        sum = 0.0
        (1...values.size).each do |index|
          forecast = alpha * values[index - 1] + complement * forecast
          error = values[index] - forecast
          sum += error * error
        end
        sum
      end

      def run(values, alpha)
        return [values[0], []] if values.size == 1

        complement = 1.0 - alpha
        level = values[0]
        fitted = []
        (1...values.size).each do |index|
          level = alpha * values[index - 1] + complement * level
          fitted[index] = level
        end
        [alpha * values.last + complement * level, fitted]
      end

      def golden_section(values, lower, upper)
        golden_ratio = (Math.sqrt(5.0) + 1.0) / 2.0
        left = upper - (upper - lower) / golden_ratio
        right = lower + (upper - lower) / golden_ratio
        left_sum = sse(values, left)
        right_sum = sse(values, right)
        while (upper - lower).abs >= 1e-12
          if left_sum < right_sum
            upper, right, right_sum = right, left, left_sum
            left = upper - (upper - lower) / golden_ratio
            left_sum = sse(values, left)
          elsif right_sum < left_sum
            lower, left, left_sum = left, right, right_sum
            right = lower + (upper - lower) / golden_ratio
            right_sum = sse(values, right)
          else
            break
          end
        end
        (upper + lower) / 2.0
      end
    end
  end
end
