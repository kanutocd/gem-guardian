# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

if ENV.fetch("COVERAGE", "false").to_s == "true"
  require "simplecov"

  SimpleCov.command_name("Minitest #{ENV.fetch("TEST_GROUP", "all")}")

  SimpleCov.start do
    enable_coverage :branch
    add_filter "/test/"
    add_filter "/sig/"
    minimum_coverage line: 90
    minimum_coverage branch: 90
  end
end

require "minitest/autorun"
require "tmpdir"
require "stringio"
require "gem/guardian"
