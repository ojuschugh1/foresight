# frozen_string_literal: true

module Foresight
  class Series
    LARGEST_VALUE = 10**15

    attr_reader :values, :exact, :keys, :frequency

    class << self
      def parse(input, keys_required:)
        case input
        when Array
          exact = input.dup
          check_values(exact, nil)
          new(exact)
        when Hash
          parse_keyed(input, keys_required)
        else
          raise InputError,
                "series must be a Hash with Date or Time keys or an Array of numbers, got #{class_of(input)}"
        end
      end

      def describe(supplied)
        Object === supplied && supplied.respond_to?(:inspect) ? supplied.inspect : "#<#{class_of(supplied)}>"
      end

      private

      def parse_keyed(input, keys_required)
        check_keys(input.keys)
        pairs = input.sort_by { |key, _| key }
        keys = pairs.map(&:first)
        exact = pairs.map(&:last)
        check_values(exact, keys)
        if keys.size >= 2
          new(exact, keys, Frequency.detect(keys))
        elsif keys_required
          raise InputError, "a keyed series needs at least two keys to determine its frequency, got #{keys.size}"
        else
          new(exact, keys)
        end
      end

      def check_keys(keys)
        date_keys = date?(keys.first)
        index = keys.index { |key| date_keys ? !date?(key) : !time?(key) }
        return unless index

        raise InputError, "series keys must be all Date values or all Time values, got #{key_text(keys[index])}"
      end

      def check_values(exact, keys)
        index = exact.index { |value| !finite_real?(value) }
        raise InputError, "series value #{observation(exact, keys, index)} is not a finite real number" if index

        index = exact.index(&:negative?)
        raise InputError, "series value #{observation(exact, keys, index)} is negative" if index

        index = exact.index { |value| value > LARGEST_VALUE }
        raise InputError, "series value #{observation(exact, keys, index)} is greater than 1e15" if index
      end

      def observation(exact, keys, index)
        location = keys ? "key #{key_text(keys[index])}" : "position #{index}"
        "#{describe(exact[index])} at #{location}"
      end

      def finite_real?(value)
        Numeric === value && value.real? && value.finite?
      end

      def date?(key)
        Date === key && !(DateTime === key)
      end

      def time?(key)
        Time === key || (Object === key && key.is_a?(Time))
      end

      def key_text(key)
        date?(key) ? key.to_s : describe(key)
      end

      def class_of(supplied)
        Kernel.instance_method(:class).bind_call(supplied)
      end
    end

    def initialize(exact, keys = nil, frequency = nil)
      @exact = exact
      @values = exact.map(&:to_f)
      @keys = keys
      @frequency = frequency
    end

    def size
      values.size
    end

    def label(index)
      keys ? keys[index] : index
    end

    def prefix(length)
      Series.new(exact.first(length))
    end

    def future_keys(count)
      (1..count).map { |period| frequency.advance(keys.last, period) }
    end
  end
end
