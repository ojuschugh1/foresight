# frozen_string_literal: true

module Foresight
  # Wichura (1988), Algorithm AS 241, Applied Statistics 37(3), 477-484
  module Normal
    CENTRAL_NUMERATOR = [
      3.38713_28727_96366_6080, 1.33141_66789_17843_7745e+2, 1.97159_09503_06551_4427e+3,
      1.37316_93765_50946_1125e+4, 4.59219_53931_54987_1457e+4, 6.72657_70927_00870_0853e+4,
      3.34305_75583_58812_8105e+4, 2.50908_09287_30122_6727e+3
    ].freeze
    CENTRAL_DENOMINATOR = [
      1.0, 4.23133_30701_60091_1252e+1, 6.87187_00749_20579_0830e+2, 5.39419_60214_24751_1077e+3,
      2.12137_94301_58659_5867e+4, 3.93078_95800_09271_0610e+4, 2.87290_85735_72194_2674e+4,
      5.22649_52788_52854_5610e+3
    ].freeze
    INTERMEDIATE_NUMERATOR = [
      1.42343_71107_49683_57734, 4.63033_78461_56545_29590, 5.76949_72214_60691_40550,
      3.64784_83247_63204_60504, 1.27045_82524_52368_38258, 2.41780_72517_74506_11770e-1,
      2.27238_44989_26918_45833e-2, 7.74545_01427_83414_07640e-4
    ].freeze
    INTERMEDIATE_DENOMINATOR = [
      1.0, 2.05319_16266_37758_82187, 1.67638_48301_83803_84940, 6.89767_33498_51000_04550e-1,
      1.48103_97642_74800_74590e-1, 1.51986_66563_61645_71966e-2, 5.47593_80849_95344_94600e-4,
      1.05075_00716_44416_84324e-9
    ].freeze
    TAIL_NUMERATOR = [
      6.65790_46435_01103_77720, 5.46378_49111_64114_36990, 1.78482_65399_17291_33580,
      2.96560_57182_85048_91230e-1, 2.65321_89526_57612_30930e-2, 1.24266_09473_88078_43860e-3,
      2.71155_55687_43487_57815e-5, 2.01033_43992_92288_13265e-7
    ].freeze
    TAIL_DENOMINATOR = [
      1.0, 5.99832_20655_58879_37690e-1, 1.36929_88092_27358_05310e-1, 1.48753_61290_85061_48525e-2,
      7.86869_13114_56132_59100e-4, 1.84631_83175_10054_68180e-5, 1.42151_17583_16445_88870e-7,
      2.04426_31033_89939_78564e-15
    ].freeze

    class << self
      def quantile(level)
        level = level.to_f.clamp(Float::MIN, 1.0 - Float::EPSILON / 2)
        offset = level - 0.5
        if offset.abs <= 0.425
          return offset * ratio(CENTRAL_NUMERATOR, CENTRAL_DENOMINATOR, 0.180625 - offset * offset)
        end

        depth = Math.sqrt(-Math.log(offset < 0 ? level : 1.0 - level))
        deviate = if depth <= 5.0
                    ratio(INTERMEDIATE_NUMERATOR, INTERMEDIATE_DENOMINATOR, depth - 1.6)
                  else
                    ratio(TAIL_NUMERATOR, TAIL_DENOMINATOR, depth - 5.0)
                  end
        offset < 0 ? -deviate : deviate
      end

      private

      def ratio(numerator, denominator, argument)
        polynomial(numerator, argument) / polynomial(denominator, argument)
      end

      def polynomial(coefficients, argument)
        coefficients.reverse_each.inject { |sum, coefficient| sum * argument + coefficient }
      end
    end
  end
end
