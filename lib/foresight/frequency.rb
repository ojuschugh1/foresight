# frozen_string_literal: true

module Foresight
  class Frequency
    DATE_UNITS = %i[day week month year].freeze

    attr_reader :unit, :seconds

    class << self
      def detect(keys)
        frequency = implied_by(keys[0], keys[1])
        keys.each_cons(2) do |earlier, later|
          next if frequency&.follows?(earlier, later)

          raise InputError, "keys #{key_text(earlier)} and #{key_text(later)} do not follow the series frequency; " \
                            "every period must be present, with a value of zero for periods without demand"
        end
        frequency
      end

      private

      def implied_by(earlier, later)
        if Date === earlier
          DATE_UNITS.map { |unit| new(unit) }.find { |frequency| frequency.follows?(earlier, later) }
        elsif later.to_r > earlier.to_r
          new(:second, later.to_r - earlier.to_r)
        end
      end

      def key_text(key)
        Date === key ? key.to_s : key.inspect
      end
    end

    def initialize(unit, seconds = nil)
      @unit = unit
      @seconds = seconds
    end

    def follows?(earlier, later)
      case unit
      when :day then later - earlier == 1
      when :week then later - earlier == 7
      when :month then later.day == earlier.day && month_index(later) == month_index(earlier) + 1
      when :year then later.month == earlier.month && later.day == earlier.day && later.year == earlier.year + 1
      else later.to_r - earlier.to_r == seconds
      end
    end

    def advance(key, periods)
      case unit
      when :day then key + periods
      when :week then key + 7 * periods
      when :month then month_after(key, periods)
      when :year then key >> (12 * periods)
      else time_after(key, periods)
      end
    end

    private

    def month_index(date)
      12 * date.year + date.month
    end

    def month_after(key, periods)
      date = key >> periods
      return date if date.day == key.day

      raise InputError, "cannot key monthly forecasts after #{key}: #{date.strftime("%Y-%m")} has no day #{key.day}"
    end

    def time_after(key, periods)
      time = key + periods * seconds
      Time === key ? key.class.at(time) : time
    end
  end
end
