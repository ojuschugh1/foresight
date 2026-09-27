# frozen_string_literal: true

require "test_helper"

class DependenciesTest < Minitest::Test
  LIB = File.join(File.dirname(__dir__), "lib")

  SCRIPT = <<~RUBY
    before = $LOADED_FEATURES.dup
    require "foresight"
    series = [0, 3, 0, 0, 5, 0, 0, 2, 0, 4, 0, 0, 1, 0, 6, 0]
    dated = series.each_with_index.to_h { |value, index| [Date.new(2026, 1, 1) >> index, value] }
    Foresight.forecast(series, count: 3, paths: 200)
    Foresight.forecast(dated, count: 3, model: :ses, strategy: :conformal)
    Foresight.classify(dated)
    Foresight.backtest(series, horizon: 2, origins: 3, paths: 200)
    Foresight.evaluate([series, dated], horizon: 2, origins: 2, paths: 200)
    begin
      Foresight.forecast(series, count: 0)
      abort "count: 0 was accepted"
    rescue Foresight::InputError
      nil
    end
    added = $LOADED_FEATURES - before
    require "rbconfig"
    puts RbConfig::CONFIG["rubylibdir"], RbConfig::CONFIG["archdir"], added
  RUBY

  def test_the_library_loads_only_its_own_files_and_the_standard_library
    output, error, status = run_ruby("--disable-gems", "-I", LIB, "-e", SCRIPT)

    assert status.success?, error
    rubylibdir, archdir, *features = output.lines(chomp: true)
    own = File.join(File.realpath(LIB), "")
    allowed = [own, *[rubylibdir, archdir].map { |directory| File.join(File.realpath(directory), "") }]
    paths = features.map { |feature| File.realpath(feature) }
    outside = paths.reject { |path| allowed.any? { |directory| path.start_with?(directory) } }
    library = Dir.glob("**/*.rb", base: LIB).map { |path| File.realpath(File.join(LIB, path)) }

    assert_empty outside, safe_inspect(features)
    assert_includes paths, File.realpath(File.join(LIB, "foresight.rb"))
    assert_equal library.sort, paths.select { |path| path.start_with?(own) }.sort
  end
end
