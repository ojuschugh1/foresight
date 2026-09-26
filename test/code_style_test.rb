# frozen_string_literal: true

require "test_helper"
require "ripper"

class CodeStyleTest < Minitest::Test
  ROOT = File.dirname(__dir__)
  SEED = 7_919
  FINDER_INDEX = [".DS", "Store"].join("_").freeze
  SKIPPED_DIRECTORIES = %w[.git tmp .venv .bundle vendor __pycache__].freeze
  SKIPPED_FILES = ["Gemfile.lock", FINDER_INDEX].freeze
  RUBY_FILE_NAMES = %w[Gemfile Rakefile foresight.gemspec].freeze
  MAGIC_COMMENT = "# frozen_string_literal: true"
  MAXIMUM_COMMENTS = 3
  DASHES = ["\u2014", "\u2013"].map(&:b).freeze
  # Marker words are bracketed so that this file passes its own check
  MARKER = /\b(?:TOD[O]|FIXM[E]|XX[X])\b/
  IDENTIFIER = /\b[A-Z][A-Za-z0-9]*(?:_[A-Z][A-Za-z0-9]*)+\b/
  REFERENCE = /\b(?:requirements?|propert(?:y|ies)|tasks?)\s+\d/i
  EXCLUDED_NAME = /#{["ama", "zon"].join}|#{["am", "zn"].join}|#{["a2", "z"].join}|\b#{["a", "ws"].join}\b/i
  RUBYGEMS_SOURCE = 'source "https://rubygems.org"'
  PIN = /\A[A-Za-z0-9][A-Za-z0-9._-]*==\S+\z/
  CODE_LINES = [
    "total = 1 + 2",
    "values = [3, 4].map { |value| value * 2 }",
    'label = "a # b"',
    "label = 'a # b'",
    'label = "#{total} #"',
    "mark = ?#",
    "marks = %w[# #]"
  ].freeze

  def test_scan_skips_ignored_paths_and_reaches_dotfiles
    ignored = %w[.git/config tmp/cache.json .venv/bin/python .bundle/config vendor/bundle/rake.rb
                 dev/retail/__pycache__/extract.pyc foresight-0.1.0.gem Gemfile.lock] << "lib/#{FINDER_INDEX}"
    ignored.each { |path| assert skipped?(path), path }
    %w[.gitignore .github/workflows/ci.yml Gemfile lib/foresight.rb].each { |path| refute skipped?(path), path }

    files = repository_files

    assert_includes files, ".gitignore"
    assert_includes files, "test/code_style_test.rb"
    assert_empty files.grep(%r{\A\.git/})
  end

  def test_ruby_files_have_at_most_three_separate_one_line_comments
    assert_equal [1], ruby_comment_lines("total = 1 # note\n")
    assert_empty ruby_comment_lines(<<~'RUBY')
      label = "a # b"
      mark = ?#
      text = <<~TEXT
        # heading
      TEXT
    RUBY
    assert_empty ruby_comment_lines("#{MAGIC_COMMENT}\n\ntotal = 1\n")
    assert_empty ruby_comment_lines("#!/usr/bin/env ruby\n#{MAGIC_COMMENT}\n")
    assert_equal [2], ruby_comment_lines("total = 1\n#{MAGIC_COMMENT}\n")
    assert_equal [2], ruby_comment_offenses("total = 1\n=begin\nnotes\n=end\n")
    assert_equal [1, 2], ruby_comment_offenses("# one\n# two\n")
    assert_equal [1, 3, 5, 7], ruby_comment_offenses("# one\n\n# two\n\n# three\n\n# four\n")
    assert_empty ruby_comment_offenses("# one\n\n# two\n\n# three\n")

    paths = repository_files.select { |path| ruby_file?(path) }
    assert_no_offenses(paths) { |content| ruby_comment_offenses(content) }
  end

  def test_reported_comment_lines_are_exactly_the_inserted_comments
    rng = Random.new(SEED)
    outcomes = Array.new(200) do
      seed = rng.rand(2**32)
      source, comments, begin_block = random_ruby_source(Random.new(seed))
      message = "seed #{seed}: #{source.inspect}"
      adjacent = comments.each_cons(2).any? { |first, second| second == first + 1 }
      rejected = begin_block || comments.size > MAXIMUM_COMMENTS || adjacent

      assert_equal comments, ruby_comment_lines(source), message
      assert_equal rejected, !ruby_comment_offenses(source).empty?, message
      rejected
    end

    assert_includes outcomes, true, "seed #{SEED}"
    assert_includes outcomes, false, "seed #{SEED}"
  end

  def test_python_files_have_at_most_three_separate_full_line_comments
    assert_empty python_comment_offenses(<<~'PYTHON')
      #!/usr/bin/env python3
      # Reads the header row
      import csv

      # Writes one row per day
      rows = []
    PYTHON
    assert_equal [2], python_comment_offenses(<<~'PYTHON')
      def read():
          """Reads the rows."""
    PYTHON
    assert_equal [1], python_comment_offenses("rows = '''a'''\n")
    assert_equal [1], python_comment_offenses("rows = []  # every row\n")
    assert_equal [1], python_comment_offenses(%(print("#")\n))
    assert_equal [1, 2], python_comment_offenses("# one\n# two\n")
    assert_equal [1, 3, 5, 7], python_comment_offenses("# one\n\n# two\n\n# three\n\n# four\n")

    paths = repository_files.select { |path| python_file?(path) }
    assert_no_offenses(paths) { |content| python_comment_offenses(content) }
  end

  def test_yaml_files_have_no_comments
    assert_equal [2], yaml_comment_offenses("on: push\n# every push\n")
    assert_equal [1], yaml_comment_offenses(%(name: "a # b"\n))
    assert_empty yaml_comment_offenses("on: push\njobs: {}\n")

    paths = repository_files.select { |path| yaml_file?(path) }
    assert_no_offenses(paths) { |content| yaml_comment_offenses(content) }
  end

  def test_code_files_hold_only_ascii
    assert_equal [2], non_ascii_lines(%(total = 1\nlabel = "caf\u00e9"\n))
    assert_empty non_ascii_lines(%(label = "cafe"\n))

    assert_no_offenses(code_files) { |content| non_ascii_lines(content) }
  end

  def test_no_file_has_an_em_or_en_dash
    assert_equal [2, 3, 5], dash_lines("a - b\nc \u2014 d\ne \u2013 f\ncaf\u00e9\n\xFF \u2014\n")

    assert_no_offenses(repository_files) { |content| dash_lines(content) }
  end

  def test_files_that_are_not_valid_utf8_fail_the_text_checks
    marker = ["TO", "DO"].join

    assert_equal ["2 is not valid UTF-8"], text_offenses("# #{marker}\ncaf\xC3\n") { |text| marker_lines(text) }
    assert_equal [2], text_offenses("caf\u00e9\n# #{marker}\n") { |text| marker_lines(text) }
  end

  def test_no_file_has_a_marker_word
    [["TO", "DO"], ["FIX", "ME"], ["XX", "X"]].map(&:join).each do |marker|
      assert_equal [2], marker_lines("total = 1\n# #{marker}: check the total\n"), marker
    end
    assert_empty marker_lines("a to-do list and an XXL size\n")

    assert_no_text_offenses { |text| marker_lines(text) }
  end

  def test_no_file_has_capitalized_words_joined_by_underscores
    [["MASE", "Scale"], ["Demand", "Class"]].map { |words| words.join("_") }.each do |term|
      assert_equal [1], identifier_lines("the #{term} value\n"), term
    end
    assert_empty identifier_lines("RUBY_VERSION DEFAULT_SEED V_H Q_h z_S demand_class\n")

    assert_no_text_offenses { |text| identifier_lines(text) }
  end

  def test_no_file_refers_to_a_numbered_requirement_property_or_task
    references = [["Require", "ment 3"], ["require", "ments 5 and 6"], ["PROP", "ERTY 2"], ["prop", "erties 10"],
                  ["Ta", "sk 8"], ["ta", "sks 4"]].map(&:join)
    references.each { |reference| assert_equal [1], reference_lines("see #{reference}\n"), reference }
    assert_empty reference_lines("Table 8.8\nthe requirements of the study\nsection 8.1\n")

    assert_no_text_offenses { |text| reference_lines(text) }
  end

  def test_no_file_contains_an_excluded_name
    [["ama", "zon"], ["am", "zn"], ["a2", "z"], ["a", "ws"]].map(&:join).each do |name|
      [name, name.upcase, name.capitalize, name.capitalize.swapcase].each do |spelling|
        assert_equal [2], excluded_name_lines("clean\nsee #{spelling} here\n"), spelling
      end
      assert_equal [1], excluded_name_lines("\xFF #{name}\n"), name
    end
    assert_empty excluded_name_lines("laws\ndraws_total\nflaws and draws\n")

    assert_no_offenses(repository_files) { |content| excluded_name_lines(content) }
  end

  def test_gemfile_names_rubygems_as_its_only_source
    gemfile = %(#{RUBYGEMS_SOURCE}\n\ngemspec\n)

    assert_equal [RUBYGEMS_SOURCE], gemfile_sources(gemfile)
    refute_equal [RUBYGEMS_SOURCE], gemfile_sources(%(#{gemfile}source "https://gems.example.org" do\nend\n))
    refute_equal [RUBYGEMS_SOURCE], gemfile_sources(gemfile.sub("rubygems.org", "gems.example.org"))
    assert_equal [RUBYGEMS_SOURCE], gemfile_sources(File.binread(File.join(ROOT, "Gemfile")))
  end

  def test_requirements_files_hold_only_exact_version_pins
    assert_empty unpinned_lines("statsforecast==2.1.1\n\nopenpyxl==3.1.5\n")
    ["--index-url https://pypi.example.org/simple", "--extra-index-url https://pypi.example.org/simple",
     "-i https://pypi.example.org/simple", "--find-links ./wheels", "-e .", "pandas>=2.3",
     "https://pypi.example.org/pandas-2.3.1.tar.gz"].each do |line|
      assert_equal [2], unpinned_lines("pandas==2.3.1\n#{line}\n"), line
    end

    paths = Dir.glob("dev/**/requirements.txt", base: ROOT)
    assert_no_offenses(paths) { |content| unpinned_lines(content) }
  end

  def test_warning_guard_raises_for_warnings_located_in_lib_or_test
    [File.join(ROOT, "lib", "foresight.rb"), File.join(ROOT, "test", "code_style_test.rb")].each do |path|
      message = "#{path}:1: warning: example\n"
      error = assert_raises(RuntimeError) { Warning.warn(message) }
      categorized = assert_raises(RuntimeError) { Warning.warn(message, category: :deprecated) }

      assert_equal message, error.message
      assert_equal message, categorized.message
    end
  end

  def test_warning_guard_passes_other_warnings_on
    minitest = method(:assert).source_location.first
    paths = [File.join(ROOT, "Rakefile"), File.join(ROOT, "lib", "missing.rb"), minitest]
    redefinition = "#{minitest}:1: warning: method redefined; discarding old total\n" \
                   "#{File.join(ROOT, "lib", "foresight.rb")}:1: warning: previous definition of total was here\n"
    messages = paths.map { |path| "#{path}:1: warning: example\n" } + [redefinition, "example without a location\n"]

    messages.each do |message|
      assert_output(nil, message) { Warning.warn(message) }
      assert_output(nil, message) { Warning.warn(message, category: :experimental) }
    end
  end

  def test_warnings_are_enabled_during_the_run
    assert_equal true, $VERBOSE
  end

  private

  def repository_files
    Dir.glob("**/*", File::FNM_DOTMATCH, base: ROOT).reject { |path| skipped?(path) }.select do |path|
      File.file?(File.join(ROOT, path))
    end
  end

  def skipped?(path)
    name = File.basename(path)
    path.split("/").intersect?(SKIPPED_DIRECTORIES) || SKIPPED_FILES.include?(name) || name.end_with?(".gem")
  end

  def code_files
    repository_files.select { |path| ruby_file?(path) || python_file?(path) || yaml_file?(path) }
  end

  def ruby_file?(path)
    File.extname(path) == ".rb" || RUBY_FILE_NAMES.include?(File.basename(path))
  end

  def python_file?(path)
    File.extname(path) == ".py"
  end

  def yaml_file?(path)
    %w[.yml .yaml].include?(File.extname(path))
  end

  def assert_no_offenses(paths)
    offenses = paths.flat_map do |path|
      yield(File.binread(File.join(ROOT, path))).map { |line| "#{path}:#{line}" }
    end

    assert_empty offenses, offenses.join("\n")
  end

  def assert_no_text_offenses(&check)
    assert_no_offenses(repository_files) { |content| text_offenses(content, &check) }
  end

  def text_offenses(content)
    text = content.dup.force_encoding(Encoding::UTF_8)
    return yield(text) if text.valid_encoding?

    invalid_utf8_lines(content).map { |line| "#{line} is not valid UTF-8" }
  end

  def line_numbers(content)
    content.each_line.with_index(1).filter_map { |line, number| number if yield(line) }
  end

  def ruby_comment_lines(source)
    first, second = source.lines.first(2).map(&:chomp)
    shebang = first.to_s.start_with?("#!")
    exempt = []
    exempt << 1 if shebang || first == MAGIC_COMMENT
    exempt << 2 if shebang && second == MAGIC_COMMENT
    Ripper.lex(source).filter_map { |(line, _), type, _| line if type == :on_comment } - exempt
  end

  def ruby_comment_offenses(source)
    begin_blocks = Ripper.lex(source).filter_map { |(line, _), type, _| line if type == :on_embdoc_beg }
    (comment_offenses(ruby_comment_lines(source)) + begin_blocks).sort
  end

  def python_comment_offenses(source)
    comments = line_numbers(source) { |line| line.lstrip.start_with?("#") }
    comments.shift if source.start_with?("#!")
    docstrings = line_numbers(source) { |line| line.include?('"""') || line.include?("'''") }
    trailing = line_numbers(source) { |line| line.include?("#") && !line.lstrip.start_with?("#") }
    (comment_offenses(comments) + docstrings + trailing).uniq.sort
  end

  def yaml_comment_offenses(source)
    line_numbers(source) { |line| line.include?("#") }
  end

  def comment_offenses(lines)
    return lines if lines.size > MAXIMUM_COMMENTS

    lines.each_cons(2).select { |first, second| second == first + 1 }.flatten.uniq
  end

  def non_ascii_lines(content)
    line_numbers(content.b) { |line| !line.ascii_only? }
  end

  def dash_lines(content)
    line_numbers(content.b) { |line| DASHES.any? { |dash| line.include?(dash) } }
  end

  def excluded_name_lines(content)
    line_numbers(content.b) { |line| line.match?(EXCLUDED_NAME) }
  end

  def invalid_utf8_lines(content)
    line_numbers(content.b) { |line| !line.dup.force_encoding(Encoding::UTF_8).valid_encoding? }
  end

  def marker_lines(text)
    line_numbers(text) { |line| line.match?(MARKER) }
  end

  def identifier_lines(text)
    line_numbers(text) { |line| line.scan(IDENTIFIER).any? { |token| token.match?(/[a-z]/) } }
  end

  def reference_lines(text)
    line_numbers(text) { |line| line.match?(REFERENCE) }
  end

  def gemfile_sources(content)
    content.lines.map(&:strip).grep(/\Asource\b/)
  end

  def unpinned_lines(content)
    line_numbers(content) { |line| !line.strip.empty? && !line.chomp.match?(PIN) }
  end

  def random_ruby_source(rng)
    lines = []
    lines << "#!/usr/bin/env ruby" if rng.rand(2).zero?
    lines << MAGIC_COMMENT if rng.rand(2).zero?
    pieces = Array.new(rng.rand(10)) { random_piece(rng) }
    begin_block = rng.rand(5).zero?
    pieces.insert(rng.rand(pieces.size + 1), [["=begin", "notes", "=end"], false]) if begin_block
    comments = []
    pieces.each do |piece, commented|
      comments << lines.size + 1 if commented
      lines.concat(piece)
    end
    [lines.map { |line| "#{line}\n" }.join, comments, begin_block]
  end

  def random_piece(rng)
    code = CODE_LINES.sample(random: rng)
    case rng.rand(6)
    when 0, 1 then [[code], false]
    when 2 then [["#{" " * rng.rand(3)}# note"], true]
    when 3 then [["#{code} # note"], true]
    when 4 then [["text = <<~TEXT", "  # heading", "TEXT"], false]
    else [["text = <<~TEXT # note", "  # heading", "TEXT"], true]
    end
  end
end
