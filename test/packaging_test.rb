# frozen_string_literal: true

require "test_helper"
require "ripper"
require "tmpdir"
require "foresight"

class PackagingTest < Minitest::Test
  ROOT = File.dirname(__dir__)
  REPOSITORY = "https://github.com/ojuschugh1/foresight"
  FINDER_INDEX = [".DS", "Store"].join("_").freeze
  COMPONENTS = %w[Naive SeasonalNaive SES CrostonClassic CrostonSBA TSB
                  GaussianStrategy CompoundStrategy ConformalStrategy].freeze
  GEM_COMMAND = File.join(RbConfig::CONFIG["bindir"], "gem")
  SERIES = [0, 3, 0, 0, 5, 0, 0, 2, 0, 4, 0, 0, 1, 0, 6, 0].freeze

  MIT_LICENSE = <<~TEXT
    MIT License

    Copyright (c) %<year>s %<holder>s

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
  TEXT

  def test_repository_root_is_a_work_tree_root_inside_no_other_work_tree
    toplevel, error, status = Open3.capture3("git", "rev-parse", "--show-toplevel", chdir: ROOT)

    assert status.success?, error
    assert_equal File.realpath(ROOT), File.realpath(toplevel.chomp)

    parent = File.dirname(ROOT)
    inside = Open3.capture3("git", "rev-parse", "--is-inside-work-tree", chdir: parent).first
    refute_equal "true", inside.chomp, "#{parent} is inside a git work tree"
  end

  def test_lib_holds_only_the_entry_file_and_the_library_directory
    lib = File.join(ROOT, "lib")

    assert_equal %w[foresight foresight.rb], (Dir.children(lib) - [FINDER_INDEX]).sort
    assert File.file?(File.join(lib, "foresight.rb"))
    assert File.directory?(File.join(lib, "foresight"))
  end

  def test_gemspec_has_the_gem_name_the_mit_license_alone_and_the_library_version
    assert_equal "foresight", gemspec.name
    assert_equal ["MIT"], gemspec.licenses
    assert_equal Foresight::VERSION, gemspec.version.to_s
  end

  def test_gemspec_requires_ruby_3_1_or_newer
    requirement = gemspec.required_ruby_version

    %w[3.1.0 4.0.7].each do |version|
      assert requirement.satisfied_by?(Gem::Version.new(version)), "#{requirement} rejects Ruby #{version}"
    end
    %w[3.0.7 3.1.0.preview1].each do |version|
      refute requirement.satisfied_by?(Gem::Version.new(version)), "#{requirement} accepts Ruby #{version}"
    end
  end

  def test_gemspec_names_the_author_and_the_repository_and_no_email
    assert_equal ["Ojus Chugh"], gemspec.authors
    assert_equal REPOSITORY, gemspec.homepage
    assert_equal REPOSITORY, gemspec.metadata["source_code_uri"]
    assert_nil gemspec.email
  end

  def test_license_is_the_mit_text_with_only_the_year_and_the_holder_filled_in
    license = File.read(File.join(ROOT, "LICENSE.txt"))
    copyright = license.match(/^Copyright \(c\) (\d{4}) (\S.*)$/)

    refute_nil copyright, "LICENSE.txt has no copyright line"
    assert_equal format(MIT_LICENSE, year: copyright[1], holder: copyright[2]), license
  end

  def test_gem_packages_only_the_library_files_the_readme_and_the_license
    library = Dir.glob("lib/foresight/**/*.rb", base: ROOT)

    assert_equal ["LICENSE.txt", "README.md", "lib/foresight.rb", *library].sort, gemspec.files.sort
  end

  def test_gem_is_pure_ruby_without_runtime_dependencies
    assert_empty gemspec.runtime_dependencies
    assert_empty gemspec.extensions
    assert_empty gemspec.files.grep(%r{\Alib/}).grep_v(/\.rb\z/)
  end

  def test_loading_the_gem_adds_only_foresight_to_the_top_level_constants
    script = <<~RUBY
      require "date"
      before = Object.constants
      require "foresight"
      puts Object.constants - before
    RUBY
    output, error, status = run_ruby("-I", File.join(ROOT, "lib"), "-e", script)

    assert status.success?, error
    assert_equal ["Foresight"], output.split
  end

  def test_no_test_file_calls_skip
    calls = Dir.glob("test/**/*.rb", base: ROOT).flat_map do |path|
      Ripper.lex(File.read(File.join(ROOT, path))).filter_map do |(line, _), type, token|
        "#{path}:#{line}" if type == :on_ident && token == "skip"
      end
    end

    assert_empty calls
  end

  def test_each_model_and_strategy_is_the_only_component_defined_in_its_own_library_file
    defined = Dir.glob("lib/foresight/*.rb", base: ROOT).sort.to_h do |path|
      [path, File.read(File.join(ROOT, path)).scan(/^\s*class\s+(\w+)/).flatten & COMPONENTS]
    end
    defined.reject! { |_, names| names.empty? }

    assert_equal COMPONENTS.sort, defined.values.flatten.sort, safe_inspect(defined)
    assert_equal COMPONENTS.size, defined.size, safe_inspect(defined)
    COMPONENTS.each do |name|
      path = File.realpath(Foresight.const_source_location(name).first)
      relative = path.delete_prefix(File.join(File.realpath(ROOT), ""))

      assert_equal [name], defined[relative], "#{name} is defined in #{path}"
    end
  end

  def test_the_built_gem_installs_and_answers_every_entry_point_in_a_clean_process
    Dir.mktmpdir do |directory|
      package = File.join(directory, "foresight.gem")
      home = File.join(directory, "home")
      gems = { "GEM_HOME" => home, "GEM_PATH" => home }
      _, error, status = run_ruby(GEM_COMMAND, "build", "foresight.gemspec", "--output", package, chdir: ROOT)

      assert status.success?, error

      _, error, status = run_ruby(GEM_COMMAND, "install", "--local", "--no-document", "--install-dir", home, package,
                                  env: gems)

      assert status.success?, error
      installed = File.join(home, "gems", "foresight-#{Foresight::VERSION}")
      files = Dir.glob("**/*", base: installed).select { |path| File.file?(File.join(installed, path)) }

      assert_equal gemspec.files.sort, files.sort

      output, error, status = run_ruby("-e", installed_script, env: gems, chdir: directory)

      assert status.success?, error
      location, dump = output.lines(chomp: true)

      assert_equal File.realpath(File.join(installed, "lib", "foresight.rb")), File.realpath(location)
      assert_equal Marshal.dump(entry_point_results).unpack1("H*"), dump
    end
  end

  private

  def installed_script
    <<~RUBY
      require "foresight"
      series = #{SERIES.inspect}
      results = [Foresight.forecast(series, count: 3, paths: 200), Foresight.classify(series),
                 Foresight.backtest(series, horizon: 2, origins: 3, paths: 200),
                 Foresight.evaluate([series, series.rotate(3)], horizon: 2, origins: 2, paths: 200)]
      puts Foresight.method(:forecast).source_location.first, Marshal.dump(results).unpack1("H*")
    RUBY
  end

  def entry_point_results
    [Foresight.forecast(SERIES, count: 3, paths: 200), Foresight.classify(SERIES),
     Foresight.backtest(SERIES, horizon: 2, origins: 3, paths: 200),
     Foresight.evaluate([SERIES, SERIES.rotate(3)], horizon: 2, origins: 2, paths: 200)]
  end

  def gemspec
    Gem::Specification.load(File.join(ROOT, "foresight.gemspec"))
  end
end
