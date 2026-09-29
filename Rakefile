# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new do |t|
  t.libs << "test"
  t.pattern = "test/**/*_test.rb"
  t.warning = true
  t.ruby_opts << "-rtest_helper"
end

task default: :test

desc "Run the calibration study and regenerate the generated document regions"
task :reproduce do
  ruby "-Ilib", "validation/study.rb"
  ruby "-Ilib", "validation/render.rb"
end
