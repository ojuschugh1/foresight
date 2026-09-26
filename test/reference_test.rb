# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "json"
require "tmpdir"
require "foresight"

class ReferenceTest < Minitest::Test
  FILES = {
    fixtures: File.expand_path("../data/fixture_series.json", __dir__),
    reference: File.expand_path("../data/reference_outputs.json", __dir__),
    requirements: File.expand_path("../dev/reference/requirements.txt", __dir__)
  }.freeze

  NAMES = {
    "Naive" => :naive,
    "SeasonalNaive" => :seasonal_naive,
    "SimpleExponentialSmoothingOptimized" => :ses,
    "CrostonClassic" => :croston_classic,
    "CrostonSBA" => :croston_sba,
    "TSB" => :tsb
  }.freeze

  DEFAULTS = { alpha: 0.1, alpha_d: 0.1, alpha_p: 0.1 }.freeze

  TOKEN = /"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/

  def test_forecasts_match_the_reference
    fixtures, reference = check_reference(FILES)
    horizon = reference["horizon"]
    fixtures.each do |fixture|
      name = fixture["name"]
      NAMES.each do |model, symbol|
        values = fixture["values"].map(&:to_f)
        options = DEFAULTS.merge(season_length: fixture["season_length"])
        forecast = Foresight::MODELS.fetch(symbol).new(values, options).forecast(horizon)
        tolerance = symbol == :ses ? SES_TOLERANCE : DETERMINISTIC_TOLERANCE
        assert_equal horizon, forecast.size, "#{model} on fixture #{name}"
        reference["fixtures"][name][model]["forecast"].each_with_index do |expected, index|
          assert_in_delta expected, forecast[index], tolerance, "#{model} on fixture #{name} at period #{index + 1}"
        end
      end
    end
  end

  def test_reference_covers_every_fixture_and_model
    fixtures, reference = check_reference(FILES)
    assert_equal fixtures.map { |fixture| fixture["name"] }.sort, reference["fixtures"].keys.sort
    reference["fixtures"].each_value { |models| assert_equal NAMES.keys, models.keys }
    %w[python_version numpy_version].each { |key| assert_kind_of String, reference[key] }
    %w[system machine].each { |key| assert_kind_of String, lookup(reference, "platform", key) }
  end

  def test_reference_numbers_survive_a_round_trip
    %w[1e-05 1.5e+16 0.0001 -0.0].each { |token| assert round_trips?(token), token }
    %w[0.10000000000000001 9007199254740993.0].each { |token| refute round_trips?(token), token }
    text = File.read(FILES[:reference])
    tokens = text.scan(TOKEN).reject { |token| token.start_with?('"') }
    assert_equal numbers(JSON.parse(text)), tokens.map { |token| JSON.parse(token) }
    assert_empty tokens.reject { |token| round_trips?(token) }
  end

  def test_missing_files_fail
    FILES.each_key do |key|
      files, message = break_copy { |copy| File.delete(copy[key]) }
      assert_equal "#{files[key]} is missing", message
    end
  end

  def test_truncated_files_fail
    %i[fixtures reference].each do |key|
      files, message = break_copy { |copy| File.truncate(copy[key], File.size(copy[key]) / 2) }
      assert message.start_with?("#{files[key]} does not parse: "), message
    end
  end

  def test_changed_fixture_file_fails
    digest = nil
    files, message = break_copy do |copy|
      File.write(copy[:fixtures], "\n", mode: "a")
      digest = Digest::SHA256.file(copy[:fixtures]).hexdigest
    end
    recorded = JSON.parse(File.read(FILES[:reference]))["fixture_file_sha256"]
    assert_equal "#{files[:reference]} records fixture_file_sha256 #{recorded.inspect}, " \
                 "but #{files[:fixtures]} has SHA-256 #{digest}", message
  end

  def test_unpinned_requirements_fail
    files, message = break_copy do |copy|
      lines = File.readlines(copy[:requirements]).reject { |line| line.start_with?("statsforecast==") }
      File.write(copy[:requirements], lines.join)
    end
    assert_equal "#{files[:requirements]} does not pin statsforecast", message
  end

  def test_changed_version_fails
    files, message = break_reference { |data| data["statsforecast_version"] = "2.0.1" }
    assert_equal "#{files[:reference]} records statsforecast_version \"2.0.1\", " \
                 "but #{files[:requirements]} pins 2.1.1", message
  end

  def test_changed_dtype_fails
    files, message = break_reference { |data| data["dtype"] = "float32" }
    assert_equal "#{files[:reference]} records dtype \"float32\", expected \"float64\"", message
  end

  def test_short_horizon_fails
    files, message = break_reference { |data| data["horizon"] = 7 }
    assert_equal "#{files[:reference]} records horizon 7, " \
                 "which is not an Integer above the longest season length 7", message
  end

  def test_changed_tsb_params_fail
    name = committed_fixtures.first["name"]
    files, message = break_reference { |data| data["fixtures"][name]["TSB"]["params"]["alpha_p"] = 0.2 }
    recorded = { "alpha_d" => 0.1, "alpha_p" => 0.2 }
    expected = { "alpha_d" => 0.1, "alpha_p" => 0.1 }
    assert_equal "#{files[:reference]} records params #{recorded.inspect} for TSB on fixture #{name}, " \
                 "expected #{expected.inspect}", message
  end

  def test_changed_season_length_fails
    fixture = committed_fixtures.find { |candidate| candidate["season_length"] > 1 }
    name = fixture["name"]
    files, message = break_reference do |data|
      data["fixtures"][name]["SeasonalNaive"]["params"]["season_length"] = 1
    end
    recorded = { "season_length" => 1 }
    expected = { "season_length" => fixture["season_length"] }
    assert_equal "#{files[:reference]} records params #{recorded.inspect} for SeasonalNaive on fixture #{name}, " \
                 "expected #{expected.inspect}", message
  end

  def test_deleted_fixture_fails
    name = committed_fixtures.first["name"]
    files, message = break_reference { |data| data["fixtures"].delete(name) }
    expected = NAMES.keys.map do |model|
      "#{files[:reference]} lacks the forecast of #{model} on fixture #{name} at periods 1 to 14"
    end
    assert_equal expected.join("\n"), message
  end

  def test_deleted_model_fails
    name = committed_fixtures.first["name"]
    files, message = break_reference { |data| data["fixtures"][name].delete("CrostonSBA") }
    assert_equal "#{files[:reference]} lacks the forecast of CrostonSBA on fixture #{name} at periods 1 to 14", message
  end

  def test_shortened_forecast_fails
    name = committed_fixtures.first["name"]
    files, message = break_reference { |data| data["fixtures"][name]["Naive"]["forecast"].pop }
    assert_equal "#{files[:reference]} lacks the forecast of Naive on fixture #{name} at period 14", message
  end

  def test_lengthened_forecast_fails
    name = committed_fixtures.first["name"]
    files, message = break_reference { |data| data["fixtures"][name]["Naive"]["forecast"] << 1.0 }
    assert_equal "#{files[:reference]} has 15 forecast values of Naive on fixture #{name}, expected 14", message
  end

  private

  def check_reference(files)
    fixtures = parse(files[:fixtures]).fetch("fixtures")
    reference = parse(files[:reference])
    requirements = read(files[:requirements])
    problems = metadata_problems(files, reference, requirements)
    horizon = lookup(reference, "horizon")
    longest = fixtures.map { |fixture| fixture["season_length"] }.max
    if horizon.is_a?(Integer) && horizon > longest
      problems.concat(entry_problems(files[:reference], fixtures, reference["fixtures"], horizon))
    else
      problems << "#{files[:reference]} records horizon #{horizon.inspect}, " \
                  "which is not an Integer above the longest season length #{longest}"
    end
    assert problems.empty?, problems.join("\n")
    [fixtures, reference]
  end

  def metadata_problems(files, reference, requirements)
    problems = []
    recorded = lookup(reference, "fixture_file_sha256")
    digest = Digest::SHA256.file(files[:fixtures]).hexdigest
    unless recorded == digest
      problems << "#{files[:reference]} records fixture_file_sha256 #{recorded.inspect}, " \
                  "but #{files[:fixtures]} has SHA-256 #{digest}"
    end
    pin = requirements[/^statsforecast==(\S+)/, 1]
    version = lookup(reference, "statsforecast_version")
    if pin.nil?
      problems << "#{files[:requirements]} does not pin statsforecast"
    elsif version != pin
      problems << "#{files[:reference]} records statsforecast_version #{version.inspect}, " \
                  "but #{files[:requirements]} pins #{pin}"
    end
    dtype = lookup(reference, "dtype")
    problems << "#{files[:reference]} records dtype #{dtype.inspect}, expected \"float64\"" unless dtype == "float64"
    problems
  end

  def entry_problems(where, fixtures, entries, horizon)
    fixtures.each_with_object([]) do |fixture, problems|
      name = fixture["name"]
      NAMES.each_key do |model|
        entry = lookup(entries, name, model)
        forecast = lookup(entry, "forecast")
        forecast = [] unless forecast.is_a?(Array)
        missing = (1..horizon).reject { |period| forecast[period - 1].is_a?(Numeric) }
        unless missing.empty?
          problems << "#{where} lacks the forecast of #{model} on fixture #{name} at #{periods(missing)}"
        end
        if forecast.size > horizon
          problems << "#{where} has #{forecast.size} forecast values of #{model} on fixture #{name}, expected #{horizon}"
        end
        next unless entry.is_a?(Hash)

        params = entry["params"]
        expected = expected_params(model, fixture)
        next if params == expected

        problems << "#{where} records params #{params.inspect} for #{model} on fixture #{name}, " \
                    "expected #{expected.inspect}"
      end
    end
  end

  def expected_params(model, fixture)
    case model
    when "SeasonalNaive" then { "season_length" => fixture["season_length"] }
    when "TSB" then { "alpha_d" => DEFAULTS[:alpha_d], "alpha_p" => DEFAULTS[:alpha_p] }
    else {}
    end
  end

  def periods(list)
    return "period #{list.first}" if list.size == 1
    return "periods #{list.first} to #{list.last}" if list.last - list.first == list.size - 1

    "periods #{list.join(", ")}"
  end

  def lookup(node, *keys)
    keys.reduce(node) { |value, key| value.is_a?(Hash) ? value[key] : nil }
  end

  def read(path)
    File.read(path)
  rescue Errno::ENOENT
    flunk "#{path} is missing"
  end

  def parse(path)
    JSON.parse(read(path))
  rescue JSON::ParserError => e
    flunk "#{path} does not parse: #{e.message}"
  end

  def committed_fixtures
    JSON.parse(File.read(FILES[:fixtures])).fetch("fixtures")
  end

  def copy_files(dir)
    FILES.to_h do |key, path|
      copy = File.join(dir, File.basename(path))
      FileUtils.cp(path, copy)
      [key, copy]
    end
  end

  def break_copy
    Dir.mktmpdir do |dir|
      files = copy_files(dir)
      yield files
      [files, assert_raises(Minitest::Assertion) { check_reference(files) }.message]
    end
  end

  def break_reference
    break_copy do |files|
      data = JSON.parse(File.read(files[:reference]))
      yield data
      File.write(files[:reference], JSON.generate(data))
    end
  end

  def round_trips?(token)
    decimal(token) == decimal(JSON.parse(token).to_s)
  end

  def decimal(text)
    mantissa, exponent = text.delete_prefix("-").split(/e/i)
    whole, fraction = mantissa.split(".")
    fraction = fraction.to_s
    digits = "#{whole}#{fraction}".sub(/\A0+/, "")
    trimmed = digits.sub(/0+\z/, "")
    negative = text.start_with?("-")
    return [negative, "0", 0] if trimmed.empty?

    [negative, trimmed, exponent.to_i - fraction.size + digits.size - trimmed.size]
  end

  def numbers(node)
    case node
    when Hash then node.values.flat_map { |value| numbers(value) }
    when Array then node.flat_map { |value| numbers(value) }
    when Numeric then [node]
    else []
    end
  end
end
