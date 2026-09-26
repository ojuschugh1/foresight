# frozen_string_literal: true

require "json"

def hand(name, season_length, values)
  { "name" => name, "season_length" => season_length, "provenance" => { "kind" => "hand" }, "values" => values }
end

def seeded(name, season_length, seed)
  values = yield(Random.new(seed))
  provenance = { "kind" => "seeded", "seed" => seed, "generator" => "dev/fixtures.rb #{name}" }
  { "name" => name, "season_length" => season_length, "provenance" => provenance, "values" => values }
end

def occasionally(random, tenths)
  random.rand(10) < tenths ? yield : 0
end

fixtures = [
  seeded("weekly_pattern", 7, 107) do |random|
    week = [22, 25, 24, 28, 35, 48, 30]
    Array.new(42) { |day| week[day % 7] + random.rand(-4..4) }
  end,
  seeded("upward_trend", 1, 109) do |random|
    Array.new(36) { |period| 10 + period + random.rand(-3..3) }
  end,
  hand("level_shift", 3, [21, 19, 22, 18, 20, 23, 17, 20, 21, 19, 22, 20, 18, 21, 20,
                          54, 57, 53, 56, 55, 58, 52, 55, 56, 54, 57, 55, 53, 56, 54]),
  seeded("decimal_amounts", 4, 113) do |random|
    profile = [58, 49, 67, 72]
    Array.new(32) { |period| (profile[period % 4] + random.rand(-6..6)) / 4.0 }
  end,
  seeded("erratic_demand", 5, 127) do |random|
    Array.new(40) { random.rand(10) < 2 ? random.rand(40..100) : random.rand(1..12) }
  end,
  seeded("intermittent_demand", 7, 131) do |random|
    Array.new(56) { occasionally(random, 3) { random.rand(2..5) } }
  end,
  seeded("lumpy_demand", 6, 137) do |random|
    Array.new(60) { occasionally(random, 3) { random.rand(10) < 3 ? random.rand(30..100) : random.rand(1..8) } }
  end,
  hand("leading_zeros", 4, [0, 0, 0, 3, 0, 0, 5, 0, 2, 4, 0, 3, 0, 0,
                            6, 2, 0, 4, 3, 0, 0, 5, 2, 0, 3, 4, 0, 2]),
  hand("trailing_zeros", 2, [8, 6, 9, 7, 5, 8, 6, 7, 4, 6, 5, 3, 6, 4, 2,
                             5, 3, 0, 4, 2, 0, 3, 0, 1, 0, 2, 0, 0, 0, 0]),
  hand("constant_level", 3, Array.new(24, 12)),
  hand("all_zeros", 7, Array.new(24, 0))
]

path = File.expand_path("../data/fixture_series.json", __dir__)
File.write(path, "#{JSON.pretty_generate({ "fixtures" => fixtures })}\n")
