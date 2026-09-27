# frozen_string_literal: true

module Foresight
  module Selector
    RULE = { smooth: :ses, erratic: :croston_sba, intermittent: :croston_sba, lumpy: :croston_sba }.freeze
    MINIMUM_HISTORY = 1

    class << self
      def model_for(classification)
        RULE.fetch(classification.demand_class)
      end

      def reason(classification, model)
        return "#{model} was specified by the caller" if model

        format("auto-selected %s for %s demand (ADI %.2f, CV squared %.2f)", model_for(classification),
               classification.demand_class, classification.adi.to_r, classification.cv_squared.to_r)
      end
    end
  end
end
