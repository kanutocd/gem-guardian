# frozen_string_literal: true

require "json"

require_relative "../../test_helper"

module Gem
  module Guardian
    class RubygemsClientTest < Minitest::Test
      SuccessResponse = Struct.new(:body) do
        def is_a?(klass)
          klass == Net::HTTPSuccess || super
        end
      end

      FailureResponse = Struct.new(:code, :message) do
        def is_a?(_klass)
          false
        end
      end

      class FakeHTTP
        def initialize(response_map)
          @response_map = response_map
        end

        def get_response(uri)
          response = @response_map.fetch(uri.path)
          response.respond_to?(:call) ? response.call(uri) : response
        end
      end

      def test_expected_sha256_supports_ruby_and_native_platforms
        http = FakeHTTP.new(
          "/api/v1/versions/rake.json" => SuccessResponse.new(
            JSON.dump([
                        { "number" => "13.2.1", "platform" => "", "sha" => "A" * 64 },
                        { "number" => "13.2.2", "platform" => "x86_64-linux", "sha256" => "B" * 64 }
                      ])
          ),
          "/api/v1/versions/nokogiri.json" => SuccessResponse.new(
            JSON.dump([
                        { "number" => "1.18.9", "platform" => "x86_64-linux", "checksum" => "C" * 64 }
                      ])
          )
        )

        client = RubygemsClient.new(http:)

        assert_equal "a" * 64, client.expected_sha256(Dependency.new(name: "rake", version: "13.2.1", platform: "ruby"))
        assert_equal "b" * 64,
                     client.expected_sha256(Dependency.new(name: "rake", version: "13.2.2", platform: "x86_64-linux"))
        assert_equal "c" * 64,
                     client.expected_sha256(Dependency.new(name: "nokogiri", version: "1.18.9",
                                                           platform: "x86_64-linux"))
      end

      def test_expected_sha256_raises_when_checksum_is_missing
        http = FakeHTTP.new(
          "/api/v1/versions/rake.json" => SuccessResponse.new(JSON.dump([{ "number" => "13.2.1", "platform" => "",
                                                                           "sha" => "" }]))
        )

        client = RubygemsClient.new(http:)

        error = assert_raises(ChecksumNotFound) do
          client.expected_sha256(Dependency.new(name: "rake", version: "13.2.1", platform: "ruby"))
        end

        assert_match(/No SHA256 found/, error.message)
      end

      def test_download_gem_writes_file
        Dir.mktmpdir do |dir|
          path = File.join(dir, "rake-13.2.1.gem")
          http = FakeHTTP.new(
            "/downloads/rake-13.2.1.gem" => SuccessResponse.new("binary-gem")
          )

          client = RubygemsClient.new(http:)
          dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")

          assert_equal path, client.download_gem(dependency, path)
          assert_equal "binary-gem", File.binread(path)
        end
      end

      def test_download_gem_wraps_errors
        http = FakeHTTP.new(
          "/downloads/rake-13.2.1.gem" => FailureResponse.new("404", "Not Found")
        )

        client = RubygemsClient.new(http:)
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")

        error = assert_raises(ArtifactFetchError) do
          client.download_gem(dependency, "/tmp/rake-13.2.1.gem")
        end

        assert_match(/Could not fetch/, error.message)
      end

      def test_trusted_publishing_provenance_parses_known_fields
        http = FakeHTTP.new(
          "/api/v1/versions/rake.json" => SuccessResponse.new(
            JSON.dump([
                        {
                          "number" => "13.2.1",
                          "platform" => "",
                          "trusted_publishing" => true,
                          "provenance" => {
                            "repository" => "https://github.com/ruby/rake",
                            "ref" => "refs/tags/v13.2.1",
                            "workflow" => "release.yml",
                            "issuer" => "https://token.actions.githubusercontent.com",
                            "subject" => "repo:ruby/rake:ref:refs/tags/v13.2.1",
                            "sha256" => "D" * 64,
                            "attestation_url" => "https://rubygems.org"
                          }
                        }
                      ])
          )
        )

        client = RubygemsClient.new(http:)
        provenance = client.trusted_publishing_provenance(Dependency.new(name: "rake", version: "13.2.1", platform: "ruby"))

        refute_nil provenance
        assert_equal true, provenance.trusted_publishing
        assert_equal "https://github.com/ruby/rake", provenance.repository
        assert_equal "refs/tags/v13.2.1", provenance.ref
        assert_equal "release.yml", provenance.workflow
        assert_equal "https://token.actions.githubusercontent.com", provenance.issuer
        assert_equal "repo:ruby/rake:ref:refs/tags/v13.2.1", provenance.subject
        assert_equal "d" * 64, provenance.sha256.downcase
        assert_equal "https://rubygems.org", provenance.attestation_url
      end

      def test_trusted_publishing_provenance_returns_nil_for_empty_untrusted_payload
        http = FakeHTTP.new(
          "/api/v1/versions/rake.json" => SuccessResponse.new(
            JSON.dump([
                        {
                          "number" => "13.2.1",
                          "platform" => "",
                          "provenance" => {}
                        }
                      ])
          )
        )

        client = RubygemsClient.new(http:)

        assert_nil client.trusted_publishing_provenance(Dependency.new(name: "rake", version: "13.2.1", platform: "ruby"))
      end

      def test_trusted_publishing_provenance_handles_non_hash_payloads
        http = FakeHTTP.new(
          "/api/v1/versions/rake.json" => SuccessResponse.new(
            JSON.dump([
                        {
                          "number" => "13.2.1",
                          "platform" => "",
                          "trusted_publishing" => true,
                          "provenance" => "signed"
                        }
                      ])
          )
        )

        client = RubygemsClient.new(http:)
        provenance = client.trusted_publishing_provenance(Dependency.new(name: "rake", version: "13.2.1", platform: "ruby"))

        refute_nil provenance
        assert_equal true, provenance.trusted_publishing
        assert_nil provenance.repository
      end
    end
  end
end
