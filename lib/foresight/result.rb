# frozen_string_literal: true

module Foresight
  Result = Struct.new(:forecast, :quantiles, :lead_time_quantiles, :model, :demand_class,
                      :reason, :strategy, :levels, keyword_init: true)
end
