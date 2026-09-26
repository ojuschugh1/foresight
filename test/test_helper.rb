# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

SES_TOLERANCE = 1e-5
DETERMINISTIC_TOLERANCE = 1e-9

module WarningGuard
  DIRECTORIES = %w[lib test].map { |name| "#{File.dirname(__dir__)}/#{name}/" }.freeze

  def warn(message, **)
    path = message[/\A(.+?):\d+: warning:/, 1]
    realpath = begin
      File.realpath(path) if path
    rescue SystemCallError
      nil
    end
    raise message if realpath && DIRECTORIES.any? { |directory| realpath.start_with?(directory) }

    super
  end
end

Warning.singleton_class.prepend(WarningGuard)

def run_ruby(*args)
  env = ENV.keys.grep(/\A(?:RUBYOPT|RUBYLIB|BUNDLER?_.*)\z/).to_h { |name| [name, nil] }
  Open3.capture3(env, RbConfig.ruby, *args)
end
