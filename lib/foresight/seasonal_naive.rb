# frozen_string_literal: true

module Foresight
  class SeasonalNaive
    attr_reader :residuals

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
      season_length = options[:season_length]
      @season = values.last(season_length)
      @residuals = (season_length...values.size).map { |index| values[index] - values[index - season_length] }
    end

    def forecast(horizon)
      Array.new(horizon) { |index| @season[index % @season.size] }
    end

    def step_factors(horizon)
      Array.new(horizon) { |index| 1 + index / @season.size }
    end

    def total_factor(horizon)
      (1..[@season.size, horizon].min).sum do |period|
        seasons = (horizon - period) / @season.size + 1
        seasons * (seasons + 1) * (2 * seasons + 1) / 6
      end
    end
  end
end
