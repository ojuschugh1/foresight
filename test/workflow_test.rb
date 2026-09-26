# frozen_string_literal: true

require "test_helper"
require "psych"

class WorkflowTest < Minitest::Test
  WORKFLOW = File.join(File.dirname(__dir__), ".github", "workflows", "ci.yml")

  def test_workflow_runs_on_every_push_and_pull_request
    assert_equal %w[push pull_request], workflow[true]
  end

  def test_jobs_run_on_ubuntu_24_04_and_the_latest_macos
    assert_equal %w[ubuntu-24.04 macos-latest], matrix["os"]
    assert_equal "${{ matrix.os }}", job["runs-on"]
  end

  def test_jobs_cover_every_ruby_series_from_3_1_to_4_0
    assert_equal %w[3.1 3.2 3.3 3.4 4.0], matrix["ruby"]
    assert_equal ["${{ matrix.ruby }}"], job["steps"].filter_map { |step| step.dig("with", "ruby-version") }
  end

  def test_a_failing_job_does_not_cancel_the_others
    assert_equal false, job.fetch("strategy")["fail-fast"]
  end

  def test_each_job_is_named_after_its_runner_and_ruby_series
    assert_equal "${{ matrix.os }} / Ruby ${{ matrix.ruby }}", job["name"]
  end

  def test_each_job_prints_the_ruby_version_before_running_the_suite
    assert_equal ["ruby -v", "bundle exec rake"], job["steps"].filter_map { |step| step["run"] }
  end

  def test_workflow_neither_installs_nor_calls_python
    refute_match(/python|pip/i, File.read(WORKFLOW))
  end

  def test_workflow_uses_only_actions_from_the_actions_and_ruby_organizations
    actions = uses_values(workflow)

    refute_empty actions
    assert_empty actions.reject { |action| action.start_with?("actions/", "ruby/") }
  end

  private

  def workflow
    Psych.safe_load_file(WORKFLOW)
  end

  def job
    workflow.fetch("jobs").fetch("test")
  end

  def matrix
    job.fetch("strategy").fetch("matrix")
  end

  def uses_values(node)
    case node
    when Hash then node.flat_map { |key, value| key == "uses" ? [value] : uses_values(value) }
    when Array then node.flat_map { |value| uses_values(value) }
    else []
    end
  end
end
