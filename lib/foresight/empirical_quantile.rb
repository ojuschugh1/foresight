# frozen_string_literal: true

module Foresight
  module EmpiricalQuantile
    def self.at(sorted, level)
      sorted[(level.to_r * sorted.size).ceil - 1]
    end
  end
end
