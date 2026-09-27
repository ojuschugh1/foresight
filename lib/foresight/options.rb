# frozen_string_literal: true

module Foresight
  module Options
    FORECAST = %i[count model levels strategy seed season_length paths windows alpha alpha_d alpha_p].freeze
    BACKTEST = %i[horizon origins step model levels strategy seed season_length paths windows
                  alpha alpha_d alpha_p].freeze
    STRATEGIES = %i[distribution conformal].freeze
    SMOOTHING = %i[alpha alpha_d alpha_p].freeze
    INTEGERS_AT_LEAST = { 0 => "a non-negative Integer", 1 => "a positive Integer",
                          2 => "an Integer of at least 2" }.freeze

    class << self
      def forecast(raw)
        check_names(raw, FORECAST)
        supplied = raw.compact
        { count: integer(supplied, :count, DEFAULT_COUNT, 1), **shared(supplied) }.freeze
      end

      def backtest(raw)
        check_names(raw, BACKTEST)
        supplied = raw.compact
        horizon = required(supplied, :horizon)
        origins = required(supplied, :origins)
        { horizon: horizon, origins: origins, step: integer(supplied, :step, horizon, 1), **shared(supplied) }.freeze
      end

      private

      def shared(supplied)
        {
          model: model(supplied),
          levels: levels(supplied),
          strategy: strategy(supplied),
          seed: integer(supplied, :seed, DEFAULT_SEED, 0),
          season_length: season_length(supplied),
          paths: integer(supplied, :paths, DEFAULT_PATHS, 1),
          windows: integer(supplied, :windows, DEFAULT_WINDOWS, 2),
          **SMOOTHING.to_h { |name| [name, smoothing(supplied, name)] }
        }
      end

      def required(supplied, name)
        raise InputError, "#{name} is required" unless supplied.key?(name)

        integer(supplied, name, nil, 1)
      end

      def check_names(raw, accepted)
        names = raw.keys
        index = names.index { |name| !accepted.include?(name) }
        return unless index

        raise InputError, "unknown option #{Series.describe(names[index])}; accepted options are #{list(accepted)}"
      end

      def integer(supplied, name, default, minimum)
        value = supplied.fetch(name, default)
        return value if Integer === value && value >= minimum

        raise invalid(name, value, INTEGERS_AT_LEAST.fetch(minimum))
      end

      def model(supplied)
        model = supplied[:model]
        return model if [nil, *MODELS.keys].include?(model)

        raise InputError, "model #{Series.describe(model)} is not provided; accepted values are #{list(MODELS.keys)}"
      end

      def levels(supplied)
        levels = supplied.fetch(:levels, DEFAULT_LEVELS)
        unless Array === levels && !levels.empty?
          raise InputError, "levels must be a non-empty Array of numbers strictly between 0 and 1"
        end

        index = levels.index { |level| !between_zero_and_one?(level) }
        raise InputError, "quantile level #{Series.describe(levels[index])} must be strictly between 0 and 1" if index

        distinct = []
        levels.each { |level| distinct << level unless distinct.include?(level) }
        distinct.sort.freeze
      end

      def strategy(supplied)
        strategy = supplied.fetch(:strategy, :distribution)
        return strategy if STRATEGIES.include?(strategy)

        raise invalid(:strategy, strategy, STRATEGIES.map(&:inspect).join(" or "))
      end

      def season_length(supplied)
        if supplied[:model] == :seasonal_naive
          season_length = supplied[:season_length]
          return season_length if Integer === season_length && season_length >= 1

          description = supplied.key?(:season_length) ? Series.describe(season_length) : "none"
          raise InputError, "SeasonalNaive requires a positive Integer season_length, got #{description}"
        end
        integer(supplied, :season_length, nil, 1) if supplied.key?(:season_length)
      end

      def smoothing(supplied, name)
        alpha = supplied.fetch(name, 0.1)
        return alpha if between_zero_and_one?(alpha)

        raise invalid(name, alpha, "a finite real number strictly between 0 and 1")
      end

      def between_zero_and_one?(number)
        Numeric === number && number.real? && number.finite? && number > 0 && number < 1
      end

      def invalid(name, value, accepted)
        InputError.new("#{name} must be #{accepted}, got #{Series.describe(value)}")
      end

      def list(names)
        names.map(&:inspect).join(", ")
      end
    end
  end
end
