# frozen_string_literal: true

module Foresight
  class Simulator
    def initialize(probability:, sizes:, horizon:, paths:, seed:)
      @probability = probability
      @sizes = sizes
      @horizon = horizon
      @paths = paths
      @seed = seed
    end

    def totals
      return Array.new(@paths, 0.0) if @sizes.empty?

      rng = Random.new(@seed)
      Array.new(@paths) do
        total = 0.0
        @horizon.times { total += @sizes[rng.rand(@sizes.size)] if rng.rand < @probability }
        total
      end
    end
  end
end
