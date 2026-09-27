# frozen_string_literal: true

module Foresight
  class Forecaster
    SMOOTH_MODELS = %i[naive seasonal_naive ses].freeze

    def initialize(options)
      @options = options
      @horizon = options[:count]
    end

    def call(series)
      check_model_history(series.size)
      classification = classify(series.exact)
      name = @options[:model] || Selector.model_for(classification)
      model_class = MODELS.fetch(name)
      kind = strategy_kind(name)
      check_strategy_history(kind, model_class, series.size)
      keys = series.future_keys(@horizon) if series.keys
      model = model_class.new(series.values, @options)
      forecast = model.forecast(@horizon)
      strategy = quantile_strategy(kind, model, series.values, forecast)
      Result.new(forecast: keyed(forecast, keys),
                 quantiles: strategy.quantiles.transform_values { |steps| keyed(steps, keys) },
                 lead_time_quantiles: strategy.lead_time_quantiles, model: name,
                 demand_class: classification&.demand_class, reason: Selector.reason(classification, @options[:model]),
                 strategy: @options[:strategy], levels: @options[:levels])
    end

    private

    def check_model_history(size)
      model_class = MODELS[@options[:model]]
      return SeasonalNaive.check_history(size, @options) if model_class == SeasonalNaive

      required = model_class ? model_class.minimum_history(@options) : Selector::MINIMUM_HISTORY
      return if size >= required

      component = model_class ? model_class.name.split("::").last : "automatic model selection"
      raise InputError, "#{component} requires at least #{required} observations, got #{size}"
    end

    def classify(exact)
      return Classifier.call(exact) unless exact.all?(&:zero?)
      return if @options[:model]

      raise InputError, "automatic selection requires at least one non-zero observation; specify a model instead"
    end

    def strategy_kind(name)
      return :conformal if @options[:strategy] == :conformal

      SMOOTH_MODELS.include?(name) ? :gaussian : :compound
    end

    def check_strategy_history(kind, model_class, size)
      required = case kind
                 when :gaussian then GaussianStrategy.minimum_history(model_class, @options)
                 when :compound then CompoundStrategy.minimum_history(model_class, @options)
                 else ConformalStrategy.minimum_history(model_class, @options, @horizon)
                 end
      return if size >= required

      raise InputError, "#{kind} quantiles need at least #{required} observations, got #{size}"
    end

    def quantile_strategy(kind, model, values, forecast)
      levels = @options[:levels]
      case kind
      when :gaussian then GaussianStrategy.new(model, horizon: @horizon, levels: levels)
      when :compound
        CompoundStrategy.new(model, horizon: @horizon, levels: levels, paths: @options[:paths], seed: @options[:seed])
      else ConformalStrategy.new(model.class, values, @options, horizon: @horizon, levels: levels, point: forecast)
      end
    end

    def keyed(steps, keys)
      keys ? keys.zip(steps).to_h : steps
    end
  end
end
