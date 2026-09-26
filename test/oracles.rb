# frozen_string_literal: true

module Oracles
  ADI_CUTOFF = 1.32r
  CV_SQUARED_CUTOFF = 0.49r

  module_function

  def classification(observations)
    demand_sizes = observations.reject { |observation| observation == 0 }.map { |size| Rational(size) }
    adi = Rational(observations.size, demand_sizes.size)
    mean = demand_sizes.inject(:+) / demand_sizes.size
    variance = demand_sizes.map { |size| (size - mean) * (size - mean) }.inject(:+) / demand_sizes.size
    cv_squared = variance / (mean * mean)
    { demand_class: demand_class(adi, cv_squared), adi: adi, cv_squared: cv_squared }
  end

  def demand_class(adi, cv_squared)
    {
      smooth: adi < ADI_CUTOFF && cv_squared < CV_SQUARED_CUTOFF,
      erratic: adi < ADI_CUTOFF && cv_squared >= CV_SQUARED_CUTOFF,
      intermittent: adi >= ADI_CUTOFF && cv_squared < CV_SQUARED_CUTOFF,
      lumpy: adi >= ADI_CUTOFF && cv_squared >= CV_SQUARED_CUTOFF
    }.key(true)
  end
end
