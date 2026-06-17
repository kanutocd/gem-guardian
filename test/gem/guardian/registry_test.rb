# frozen_string_literal: true

require_relative "../../test_helper"

module Gem
  module Guardian
    class RegistryTest < Minitest::Test
      FakeSpec = Struct.new(:name, :version, :platform, keyword_init: true)
      FakeSource = Struct.new(:uri)

      class FakeSpecFetcher
        attr_reader :type

        def initialize(entries)
          @entries = entries
        end

        def detect(type)
          @type = type
          @entries.select { |entry| yield entry.first }
        end
      end

      def test_latest_specs_returns_entries_from_visible_sources
        source = FakeSource.new(URI("https://rubygems.org/"))
        spec = FakeSpec.new(name: "rake", version: Gem::Version.new("13.2.1"), platform: "ruby")
        fetcher = FakeSpecFetcher.new([[spec, source]])

        entries = Registry.new(sources: [source], spec_fetcher: fetcher).latest_specs

        assert_equal :latest, fetcher.type
        assert_equal 1, entries.size
        assert_equal "rake", entries.first.name
        assert_equal "13.2.1", entries.first.version
        assert_equal "ruby", entries.first.platform
        assert_equal "https://rubygems.org", entries.first.source
      end

      def test_each_latest_spec_honors_limit
        source = FakeSource.new(URI("https://rubygems.org/"))
        specs = [
          [FakeSpec.new(name: "a", version: Gem::Version.new("1.0.0"), platform: "ruby"), source],
          [FakeSpec.new(name: "b", version: Gem::Version.new("2.0.0"), platform: "ruby"), source]
        ]

        entries = Registry.new(sources: [source], spec_fetcher: FakeSpecFetcher.new(specs)).latest_specs(limit: 1)

        assert_equal ["a"], entries.map(&:name)
      end

      def test_each_latest_spec_returns_enumerator
        registry = Registry.new(sources: ["https://rubygems.org/"], spec_fetcher: FakeSpecFetcher.new([]))

        assert_kind_of Enumerator, registry.each_latest_spec
      end

      def test_entry_converts_to_dependency_with_source
        entry = Registry::Entry.new(name: "rake", version: "13.2.1", platform: "ruby", source: "https://rubygems.org")

        dependency = entry.dependency

        assert_equal "rake", dependency.name
        assert_equal "13.2.1", dependency.version
        assert_equal "ruby", dependency.platform
        assert_equal "https://rubygems.org", dependency.source
      end

      def test_sanitizes_embedded_credentials_from_source_uri
        source = FakeSource.new(URI("https://user:secret@rubygems.pkg.github.com/kanutocd/"))
        spec = FakeSpec.new(name: "private-gem", version: Gem::Version.new("0.1.0"), platform: "ruby")

        entries = Registry.new(sources: [source], spec_fetcher: FakeSpecFetcher.new([[spec, source]])).latest_specs

        assert_equal "https://rubygems.pkg.github.com/kanutocd", entries.first.source
      end

      def test_normalize_sources_returns_source_list_for_arrays
        registry = Registry.new(sources: ["https://rubygems.org/"], spec_fetcher: FakeSpecFetcher.new([]))

        normalized = registry.send(:normalize_sources, ["https://rubygems.org/"])

        assert_respond_to normalized, :each_source
        assert_kind_of Gem::SourceList, normalized
      end

      def test_normalize_sources_preserves_source_lists
        source_list = Gem::SourceList.from(["https://rubygems.org/"])
        registry = Registry.new(sources: source_list, spec_fetcher: FakeSpecFetcher.new([]))

        assert_same source_list, registry.send(:normalize_sources, source_list)
      end

      def test_platform_string_defaults_blank_platform_to_ruby
        source = FakeSource.new(URI("https://rubygems.org/"))
        spec = FakeSpec.new(name: "blank-platform", version: Gem::Version.new("1.0.0"), platform: "")
        entries = Registry.new(sources: [source], spec_fetcher: FakeSpecFetcher.new([[spec, source]])).latest_specs

        assert_equal "ruby", entries.first.platform
      end

      def test_sanitized_source_uri_accepts_plain_source_strings
        registry = Registry.new(sources: ["https://rubygems.org/"], spec_fetcher: FakeSpecFetcher.new([]))

        assert_equal "https://rubygems.org", registry.send(:sanitized_source_uri, "https://user:secret@rubygems.org/")
      end


      def test_each_latest_spec_with_nil_limit_yields_all_entries
        source = FakeSource.new(URI("https://rubygems.org/"))
        specs = [
          [FakeSpec.new(name: "a", version: Gem::Version.new("1.0.0"), platform: "ruby"), source],
          [FakeSpec.new(name: "b", version: Gem::Version.new("2.0.0"), platform: "ruby"), source]
        ]

        entries = Registry.new(sources: [source], spec_fetcher: FakeSpecFetcher.new(specs)).latest_specs(limit: nil)

        assert_equal %w[a b], entries.map(&:name)
      end

      def test_platform_string_preserves_non_blank_platform
        registry = Registry.new(sources: ["https://rubygems.org/"], spec_fetcher: FakeSpecFetcher.new([]))

        assert_equal "x86_64-linux", registry.send(:platform_string, "x86_64-linux")
      end

      def test_sanitized_source_uri_accepts_uri_objects
        registry = Registry.new(sources: ["https://rubygems.org/"], spec_fetcher: FakeSpecFetcher.new([]))

        assert_equal "https://rubygems.org", registry.send(:sanitized_source_uri, URI("https://user:secret@rubygems.org/"))
      end


      def test_private_platform_string_defaults_blank_to_ruby
        registry = Registry.new(spec_fetcher: FakeSpecFetcher.new([]))

        assert_equal "ruby", registry.send(:platform_string, "")
      end

      def test_private_sanitized_source_uri_accepts_plain_string
        registry = Registry.new(spec_fetcher: FakeSpecFetcher.new([]))

        assert_equal "https://rubygems.pkg.github.com/kanutocd",
                     registry.send(:sanitized_source_uri, "https://user:secret@rubygems.pkg.github.com/kanutocd/")
      end

    end
  end
end
