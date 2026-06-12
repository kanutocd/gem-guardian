# frozen_string_literal: true

require "json"

require_relative "../../test_helper"

module Gem
  module Guardian
    # rubocop:disable Metrics/ClassLength, Metrics/AbcSize, Metrics/MethodLength, Layout/LineLength,
    #                 Minitest/AssertTruthy
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
        assert(provenance.trusted_publishing)
        assert_equal "https://github.com/ruby/rake", provenance.repository
        assert_equal "refs/tags/v13.2.1", provenance.ref
        assert_equal "release.yml", provenance.workflow
        assert_equal "https://token.actions.githubusercontent.com", provenance.issuer
        assert_equal "repo:ruby/rake:ref:refs/tags/v13.2.1", provenance.subject
        assert_equal "d" * 64, provenance.sha256.downcase
        assert_equal "https://rubygems.org", provenance.attestation_url
      end

      def test_trusted_publishing_provenance_parses_nested_source_commit_payload
        http = FakeHTTP.new(
          "/api/v1/versions/cdc-sidekiq.json" => SuccessResponse.new(
            JSON.dump([
                        {
                          "number" => "0.1.1",
                          "platform" => "",
                          "provenance" => {
                            "source_commit" => "kanutocd/cdc-sidekiq@a7edb75",
                            "build_file" => ".github/workflows/release.yml",
                            "transparency_log_entry" => "https://search.example/log/123",
                            "sha256" => "d91d298d9b04d8bf3462dda766a3b69046d287004c118666c4d4d367eac49dcd"
                          }
                        }
                      ])
          )
        )

        client = RubygemsClient.new(http:)
        provenance = client.trusted_publishing_provenance(Dependency.new(name: "cdc-sidekiq", version: "0.1.1", platform: "ruby"))

        refute_nil provenance
        assert(provenance.trusted_publishing)
        assert_equal "kanutocd/cdc-sidekiq@a7edb75", provenance.ref
        assert_equal ".github/workflows/release.yml", provenance.workflow
        assert_equal "https://search.example/log/123", provenance.attestation_url
        assert_equal "d91d298d9b04d8bf3462dda766a3b69046d287004c118666c4d4d367eac49dcd", provenance.sha256
      end

      def test_trusted_publishing_provenance_falls_back_to_version_page_html
        http = FakeHTTP.new(
          "/api/v1/versions/sidekiq.json" => SuccessResponse.new(
            JSON.dump([
                        {
                          "number" => "8.1.6",
                          "platform" => ""
                        }
                      ])
          ),
          "/gems/sidekiq/versions/8.1.6" => SuccessResponse.new(
            "<html><body>Provenance: Built and signed on GitHub Actions "\
            "Build summary Source Commit kanutocd/sidekiq@a7edb75 "\
            "Build File .github/workflows/release.yml transparency log entry "\
            "https://example.test/log/123 SHA 256 checksum "\
            "be20cd051124b1a16cf97ea9157137abbd30a515c16a5ae9312d2eadd045e40f</body></html>"
          )
        )

        client = RubygemsClient.new(http:)
        provenance = client.trusted_publishing_provenance(Dependency.new(name: "sidekiq", version: "8.1.6", platform: "ruby"))

        refute_nil provenance
        assert_equal "https://github.com/kanutocd/sidekiq", provenance.repository
        assert_equal "a7edb75", provenance.ref
        assert_equal "GitHub Actions", provenance.workflow
        assert_equal "GitHub Actions", provenance.issuer
        assert_equal "kanutocd/sidekiq@a7edb75", provenance.subject
        assert_equal "https://example.test/log/123", provenance.attestation_url
        assert_equal "be20cd051124b1a16cf97ea9157137abbd30a515c16a5ae9312d2eadd045e40f", provenance.sha256
      end

      def test_trusted_publishing_provenance_uses_attestations_api
        certificate = build_attestation_certificate(
          repository: "kanutocd/sidekiq",
          commit: "a7edb75",
          ref: "refs/tags/v8.1.6",
          workflow: ".github/workflows/release.yml",
          build_summary_url: "https://rubygems.org/attestations/123"
        )

        http = FakeHTTP.new(
          "/api/v1/versions/sidekiq.json" => SuccessResponse.new(
            JSON.dump([
                        {
                          "number" => "8.1.6",
                          "platform" => ""
                        }
                      ])
          ),
          "/api/v1/attestations/sidekiq-8.1.6.json" => SuccessResponse.new(
            JSON.dump([
                        {
                          "verificationMaterial" => {
                            "x509CertificateChain" => {
                              "certificates" => [certificate.to_pem]
                            }
                          }
                        }
                      ])
          )
        )

        client = RubygemsClient.new(http:)
        provenance = client.trusted_publishing_provenance(Dependency.new(name: "sidekiq", version: "8.1.6", platform: "ruby"))

        refute_nil provenance
        assert_equal "https://github.com/kanutocd/sidekiq", provenance.repository
        assert_equal "a7edb75", provenance.ref
        assert_equal ".github/workflows/release.yml", provenance.workflow
        assert_equal "https://token.actions.githubusercontent.com", provenance.issuer
        assert_equal "kanutocd/sidekiq@a7edb75", provenance.subject
        assert_equal "https://rubygems.org/attestations/123", provenance.attestation_url
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
        assert(provenance.trusted_publishing)
        assert_nil provenance.repository
      end

      private

      def build_attestation_certificate(repository:, commit:, ref:, workflow:, build_summary_url:)
        key = OpenSSL::PKey::RSA.new(2048)
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = 1
        cert.subject = OpenSSL::X509::Name.parse("/CN=Sigstore Test")
        cert.issuer = cert.subject
        cert.public_key = key.public_key
        cert.not_before = Time.now - 60
        cert.not_after = Time.now + 3600

        ef = OpenSSL::X509::ExtensionFactory.new
        ef.subject_certificate = cert
        ef.issuer_certificate = cert

        cert.add_extension(ef.create_extension("subjectAltName",
                                               "URI:https://github.com/#{repository}/#{workflow}@#{ref}", false))
        cert.add_extension(OpenSSL::X509::Extension.new("1.3.6.1.4.1.57264.1.5", repository, false))
        cert.add_extension(OpenSSL::X509::Extension.new("1.3.6.1.4.1.57264.1.3", commit, false))
        cert.add_extension(OpenSSL::X509::Extension.new("1.3.6.1.4.1.57264.1.14", ref, false))
        cert.add_extension(OpenSSL::X509::Extension.new("1.3.6.1.4.1.57264.1.21", build_summary_url, false))
        cert.sign(key, OpenSSL::Digest.new("SHA256"))
        cert
      end
    end
    # rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/MethodLength, Layout/LineLength,
    #                Minitest/AssertTruthy
  end
end
