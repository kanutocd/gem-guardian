# frozen_string_literal: true

require "rubygems/spec_fetcher"
require "uri"

module Gem
  module Guardian
    # Enumerates gems visible through RubyGems-compatible registry sources.
    #
    # This is intentionally a small library API rather than a supported CLI command.
    # It is useful for research scripts that want to inspect the latest gem entries
    # visible from the current `Gem.sources` configuration, including private
    # RubyGems-compatible registries such as GitHub Packages, Gemfury, CodeArtifact,
    # or self-hosted gem servers.
    class Registry
      # One latest gem entry discovered from a registry index.
      Entry = Data.define(:name, :version, :platform, :source) do
        # Converts this registry entry into a gem-guardian dependency.
        def dependency
          Dependency.new(name:, version:, platform:, source:)
        end
      end

      # @param sources [Gem::SourceList, Array<String, Gem::Source>] registry sources to inspect
      # @param spec_fetcher [Gem::SpecFetcher] RubyGems spec fetcher
      def initialize(sources: Gem.sources, spec_fetcher: nil)
        @sources = normalize_sources(sources)
        @spec_fetcher = spec_fetcher || Gem::SpecFetcher.new(@sources)
      end

      # Yields latest gem entries visible from the configured sources.
      def each_latest_spec(limit: nil)
        return enum_for(:each_latest_spec, limit:) unless block_given?

        count = 0
        latest_spec_tuples.each do |spec, source|
          break if limit && count >= limit

          yield build_entry(spec, source)
          count += 1
        end
      end

      # Returns latest gem entries visible from the configured sources.
      def latest_specs(limit: nil)
        each_latest_spec(limit:).to_a
      end

      private

      def latest_spec_tuples
        @spec_fetcher.detect(:latest) { true }
      end

      def build_entry(spec, source)
        Entry.new(
          name: spec.name,
          version: spec.version.to_s,
          platform: platform_string(spec.platform),
          source: sanitized_source_uri(source)
        )
      end

      def platform_string(platform)
        value = platform.to_s
        value.empty? ? "ruby" : value
      end

      def normalize_sources(sources)
        return sources if sources.respond_to?(:each_source)

        Gem::SourceList.from(Array(sources))
      end

      def sanitized_source_uri(source)
        uri = URI.parse(source.respond_to?(:uri) ? source.uri.to_s : source.to_s)
        uri.user = nil
        uri.password = nil
        uri.to_s.delete_suffix("/")
      end
    end
  end
end
