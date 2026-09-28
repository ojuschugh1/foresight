# frozen_string_literal: true

require "test_helper"
require "psych"
require "foresight"

class CitationTest < Minitest::Test
  ROOT = File.dirname(__dir__)
  REPOSITORY = "https://github.com/ojuschugh1/foresight"
  FORMAT_KEYS = %w[abstract authors cff-version commit contact date-released doi identifiers keywords license
                   license-url message preferred-citation references repository repository-artifact repository-code
                   title type url version].freeze
  REQUIRED_KEYS = %w[authors cff-version message title].freeze

  def test_citation_file_uses_version_1_2_0_of_the_format
    assert_equal "1.2.0", citation["cff-version"]
  end

  def test_citation_file_describes_the_foresight_software_with_a_message
    assert_equal "software", citation["type"]
    assert_equal "foresight", citation["title"]
    assert_kind_of String, citation["message"]
    refute_empty citation["message"]
  end

  def test_version_is_the_library_version
    assert_equal Foresight::VERSION, citation["version"]
  end

  def test_the_one_author_is_given_by_name_only
    assert_equal [{ "family-names" => "Chugh", "given-names" => "Ojus" }], citation["authors"]
  end

  def test_license_is_mit_and_equals_the_only_license_of_the_gemspec
    assert_equal "MIT", citation["license"]
    assert_equal [citation["license"]], gemspec.licenses
  end

  def test_repository_is_the_github_url_that_the_gemspec_names
    assert_equal REPOSITORY, citation["repository-code"]
    assert_equal gemspec.metadata["source_code_uri"], citation["repository-code"]
  end

  def test_top_level_keys_are_defined_by_the_format_and_include_the_required_keys
    assert_empty citation.keys - FORMAT_KEYS
    assert_empty REQUIRED_KEYS - citation.keys
  end

  def test_no_key_at_any_depth_is_email
    keys = nested_keys(citation)

    assert_includes keys, "given-names"
    refute_includes keys, "email"
  end

  private

  def citation
    Psych.safe_load(File.read(File.join(ROOT, "CITATION.cff")))
  end

  def gemspec
    Gem::Specification.load(File.join(ROOT, "foresight.gemspec"))
  end

  def nested_keys(node)
    case node
    when Hash then node.flat_map { |key, value| [key, *nested_keys(value)] }
    when Array then node.flat_map { |value| nested_keys(value) }
    else []
    end
  end
end
