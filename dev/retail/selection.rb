# frozen_string_literal: true

require "digest"

module Selection
  Candidate = Struct.new(:stock_code, :demand_class, :length, keyword_init: true)
  Shortfall = Struct.new(:demand_class, :target, :included, keyword_init: true)
  Choice = Struct.new(:chosen, :shortfalls, keyword_init: true)

  class << self
    def choose(candidates, classes:, minimum_length:, target:, seed:)
      chosen = classes.to_h do |demand_class|
        eligible = candidates.select do |candidate|
          candidate.demand_class == demand_class && candidate.length >= minimum_length
        end
        [demand_class, eligible.sort_by { |candidate| rank(seed, candidate.stock_code) }.first(target)]
      end
      shortfalls = chosen.filter_map do |demand_class, picked|
        Shortfall.new(demand_class: demand_class, target: target, included: picked.size) if picked.size < target
      end
      Choice.new(chosen: chosen, shortfalls: shortfalls)
    end

    private

    def rank(seed, stock_code)
      Digest::SHA256.hexdigest("#{seed}:#{stock_code}")
    end
  end
end
