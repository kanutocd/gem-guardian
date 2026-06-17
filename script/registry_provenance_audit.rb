#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "gem/guardian"

limit = ENV.fetch("MAX_GEMS", nil)&.to_i
source = ENV.fetch("REGISTRY_SOURCE", nil)
sources = source ? [source] : Gem.sources

registry = Gem::Guardian::Registry.new(sources:)
audit = Gem::Guardian::RegistryAudit.new(registry:)
result = audit.run(limit:)
counts = result.counts

puts "Registry provenance audit"
puts
puts "Sources:"
Array(sources.respond_to?(:to_a) ? sources.to_a : sources).each do |configured_source|
  uri = configured_source.respond_to?(:uri) ? configured_source.uri : configured_source
  puts "- #{uri}"
end
puts
puts "Latest gems scanned: #{result.total}"
puts
puts "Provenance:"
puts "  verified:    #{counts.fetch(:verified, 0)}"
puts "  unsupported: #{counts.fetch(:unsupported, 0)}"
puts "  mismatch:    #{counts.fetch(:mismatch, 0)}"
puts "  error:       #{counts.fetch(:error, 0)}"

unless result.unsupported.empty?
  puts
  puts "Unsupported:"
  result.unsupported.first(50).each do |entry_result|
    dependency = entry_result.dependency
    puts "- #{dependency.name} #{dependency.version} #{dependency.platform}"
  end
  puts "..." if result.unsupported.size > 50
end
