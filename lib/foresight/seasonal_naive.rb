# frozen_string_literal: true

module Foresight
  class SeasonalNaive
    def self.minimum_history(options)
      options[:season_length]
    end

    def self.check_history(size, options)
      required = minimum_history(options)
      return if size >= required

      raise InputError, "SeasonalNaive requires at least #{required} observations (its season_length), got #{size}"
    end

    def initialize(values, options)
      SeasonalNaive.check_history(values.size, options)
      @season = values.last(options[:season_length])
    end

    def forecast(horizon)
      Array.new(horizon) { |index| @season[index % @season.size] }
    end
  end
end
