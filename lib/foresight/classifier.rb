# frozen_string_literal: true

module Foresight
  Classification = Struct.new(:demand_class, :adi, :cv_squared, keyword_init: true)

  module Classifier
    # Cutoffs from Syntetos, Boylan and Croston (2005)
    ADI_CUTOFF = Rational(132, 100)
    CV2_CUTOFF = Rational(49, 100)

    class << self
      def call(exact_values)
        sizes = exact_values.map(&:to_r).reject(&:zero?)
        raise InputError, "classification requires at least one non-zero observation" if sizes.empty?

        adi = Rational(exact_values.size, sizes.size)
        mean = sizes.sum / sizes.size
        cv_squared = sizes.sum { |size| (size - mean)**2 } / sizes.size / mean**2
        Classification.new(demand_class: demand_class(adi, cv_squared), adi: adi.to_f, cv_squared: cv_squared.to_f)
      end

      private

      def demand_class(adi, cv_squared)
        if adi >= ADI_CUTOFF
          cv_squared >= CV2_CUTOFF ? :lumpy : :intermittent
        else
          cv_squared >= CV2_CUTOFF ? :erratic : :smooth
        end
      end
    end
  end
end
