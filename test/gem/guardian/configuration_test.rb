# frozen_string_literal: true

require_relative "../../test_helper"

module Gem
  module Guardian
    class ConfigurationTest < Minitest::Test
      SuccessResponse = Struct.new(:body) do
        def is_a?(klass)
          klass == Net::HTTPSuccess || super
        end
      end

      class FakeHTTP
        def initialize(response)
          @response = response
        end

        def get_response(_uri)
          @response
        end
      end

      def test_load_returns_empty_configuration_when_file_is_missing
        Dir.mktmpdir do |dir|
          config = Configuration.load(cwd: dir)

          refute config.checksum_providers?
          assert_empty config.checksum_providers
        end
      end

      def test_load_builds_source_scoped_url_checksum_providers
        Dir.mktmpdir do |dir|
          File.write(
            File.join(dir, ".gem-guardian.yml"),
            <<~YAML
              checksum_providers:
                - name: contribsys-sidekiq
                  source: https://gems.contribsys.com/
                  template: https://gems.contribsys.com/checksums/{filename}.sha256
            YAML
          )

          config = Configuration.load(cwd: dir)

          assert config.checksum_providers?
          assert_equal 1, config.checksum_providers.size
        end
      end

      def test_load_rejects_invalid_root_shape
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, ".gem-guardian.yml"), "- nope\n")

          error = assert_raises(Error) { Configuration.load(cwd: dir) }

          assert_match(/must contain a YAML mapping/, error.message)
        end
      end

      def test_load_rejects_non_array_checksum_providers
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, ".gem-guardian.yml"), "checksum_providers: nope\n")

          error = assert_raises(Error) { Configuration.load(cwd: dir) }

          assert_match(/checksum_providers must be an array/, error.message)
        end
      end

      def test_load_rejects_provider_without_template
        Dir.mktmpdir do |dir|
          File.write(
            File.join(dir, ".gem-guardian.yml"),
            <<~YAML
              checksum_providers:
                - name: missing-template
            YAML
          )

          error = assert_raises(Error) { Configuration.load(cwd: dir) }

          assert_match(/template is required/, error.message)
        end
      end

      def test_source_scoped_provider_only_applies_to_matching_sources
        sha = "a" * 64
        provider = ChecksumProvider::Url.new(
          template: "https://checksums.example/{filename}.sha256",
          http: FakeHTTP.new(SuccessResponse.new(sha)),
          provider_name: "publisher"
        )
        scoped = ChecksumProvider::SourceScoped.new(source: "https://gems.contribsys.com/", provider:)
        matching = Dependency.new(name: "sidekiq-pro", version: "8.1.6", platform: "ruby",
                                  source: "https://gems.contribsys.com/")
        other = Dependency.new(name: "sidekiq", version: "8.1.6", platform: "ruby",
                               source: "https://rubygems.org/")

        result = scoped.checksum_for(matching, client: RubygemsClient.new)

        assert_equal sha, result.sha256
        assert_nil scoped.checksum_for(other, client: RubygemsClient.new)
      end

      def test_source_scoped_provider_matches_sources_with_credentials
        sha = "b" * 64
        provider = ChecksumProvider::Url.new(
          template: "https://checksums.example/{filename}.sha256",
          http: FakeHTTP.new(SuccessResponse.new(sha)),
          provider_name: "publisher"
        )
        scoped = ChecksumProvider::SourceScoped.new(source: "https://gems.contribsys.com/", provider:)
        dependency = Dependency.new(
          name: "sidekiq-pro",
          version: "8.1.6",
          platform: "ruby",
          source: "https://user:REDACTED@gems.contribsys.com/"
        )

        result = scoped.checksum_for(dependency, client: RubygemsClient.new)

        assert_equal sha, result.sha256
      end

    end
  end
end
