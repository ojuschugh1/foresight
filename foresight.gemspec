# frozen_string_literal: true

require_relative "lib/foresight/version"

Gem::Specification.new do |spec|
  spec.name    = "foresight"
  spec.version = Foresight::VERSION
  spec.authors = ["Ojus Chugh"]

  spec.summary  = "Probabilistic demand forecasting for smooth and intermittent series"
  spec.homepage = "https://github.com/ojuschugh1/foresight"
  spec.licenses = ["MIT"]

  spec.required_ruby_version = ">= 3.1"

  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.glob(%w[lib/foresight.rb lib/foresight/**/*.rb README.md LICENSE.txt], base: __dir__)
end
