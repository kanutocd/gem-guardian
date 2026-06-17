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

      RedirectResponse = Struct.new(:location) do
        def is_a?(klass)
          klass == Net::HTTPRedirection || super
        end

        def [](key)
          key.to_s.casecmp("location").zero? ? location : nil
        end
      end

      class FakeHTTP
        attr_reader :requests

        def initialize(response_map)
          @response_map = response_map
          @requests = []
        end

        def get_response(uri)
          @requests << [uri, {}]
          response = @response_map.fetch(uri.path)
          response.respond_to?(:call) ? response.call(uri) : response
        end

        def request(request)
          @requests << [request.uri, request.to_hash]
          response = @response_map.fetch(request.uri.path)
          response.respond_to?(:call) ? response.call(request.uri) : response
        end
      end

      FakeCredentials = Struct.new(:credentials) do
        def credentials_for(_uri)
          credentials
        end
      end

      FakeSpec = Struct.new(:name, :version, :platform, keyword_init: true)

      class FakeSource
        attr_reader :uri, :downloaded

        def initialize(uri, body: "gem-binary")
          @uri = URI(uri)
          @body = body
          @downloaded = []
        end

        def download(spec, dir)
          @downloaded << [spec, dir]
          filename = spec.platform.to_s == "ruby" ? "#{spec.name}-#{spec.version}.gem" :
                                                     "#{spec.name}-#{spec.version}-#{spec.platform}.gem"
          path = File.join(dir, filename)
          File.binwrite(path, @body)
          path
        end
      end

      FakeSpecFetcher = Struct.new(:specs, keyword_init: true) do
        def spec_for_dependency(_dependency, _matching_platform)
          [specs, []]
        end
      end

      def client_with_spec(http:, source:, spec:, credentials: Bundler.settings)
        RubygemsClient.new(
          http:,
          credentials:,
          spec_fetcher: FakeSpecFetcher.new(specs: [[spec, source]]),
          sources: [source.uri.to_s]
        )
      end

      def fake_spec(name:, version:, platform: "ruby")
        FakeSpec.new(name:, version: Gem::Version.new(version), platform:)
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
            "/gems/rake-13.2.1.gem" => SuccessResponse.new("binary-gem")
          )

          source = FakeSource.new("https://rubygems.org/")
          spec = fake_spec(name: "rake", version: "13.2.1")
          client = client_with_spec(http:, source:, spec:)
          dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")

          assert_equal path, client.download_gem(dependency, path)
          assert_equal "binary-gem", File.binread(path)
        end
      end

      def test_download_gem_follows_redirects
        Dir.mktmpdir do |dir|
          path = File.join(dir, "rake-13.2.1.gem")
          http = FakeHTTP.new(
            "/gems/rake-13.2.1.gem" => RedirectResponse.new(URI("https://objects.example/rake-13.2.1.gem")),
            "/rake-13.2.1.gem" => SuccessResponse.new("redirected-gem")
          )

          source = FakeSource.new("https://rubygems.org/")
          spec = fake_spec(name: "rake", version: "13.2.1")
          client = client_with_spec(http:, source:, spec:)
          dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")

          assert_equal path, client.download_gem(dependency, path)
          assert_equal "redirected-gem", File.binread(path)
        end
      end

      def test_download_gem_uses_dependency_source_and_github_packages_bearer_token
        Dir.mktmpdir do |dir|
          path = File.join(dir, "cdc-orchestrator-pro-0.1.0.gem")
          http = FakeHTTP.new(
            "/kanutocd/gems/cdc-orchestrator-pro-0.1.0.gem" => SuccessResponse.new("private-gem")
          )
          dependency = Dependency.new(
            name: "cdc-orchestrator-pro",
            version: "0.1.0",
            platform: "ruby",
            source: "https://rubygems.pkg.github.com/kanutocd/"
          )

          source = FakeSource.new("https://rubygems.pkg.github.com/kanutocd/")
          spec = fake_spec(name: "cdc-orchestrator-pro", version: "0.1.0")
          client = client_with_spec(http:, source:, spec:, credentials: FakeCredentials.new("kanutocd:test-token"))

          assert_equal path, client.download_gem(dependency, path)

          uri, headers = http.requests.fetch(0)
          assert_equal "rubygems.pkg.github.com", uri.host
          assert_equal ["Bearer test-token"], headers["authorization"]
          assert_equal "private-gem", File.binread(path)
        end
      end

      def test_download_gem_wraps_errors
        http = FakeHTTP.new(
          "/gems/rake-13.2.1.gem" => FailureResponse.new("404", "Not Found")
        )

        source = FakeSource.new("https://rubygems.org/")
        spec = fake_spec(name: "rake", version: "13.2.1")
        client = client_with_spec(http:, source:, spec:)
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")

        error = assert_raises(ArtifactFetchError) do
          client.download_gem(dependency, "/tmp/rake-13.2.1.gem")
        end

        assert_match(/Could not fetch/, error.message)
      end


      def test_resolve_dependency_uses_first_configured_source_containing_gem
        rubygems_source = FakeSource.new("https://rubygems.org/")
        github_source = FakeSource.new("https://user:secret@rubygems.pkg.github.com/kanutocd/")
        specs = [
          [FakeSpec.new(name: "cdc-orchestrator-pro", version: Gem::Version.new("0.1.0"), platform: "ruby"), github_source]
        ]
        client = RubygemsClient.new(
          spec_fetcher: FakeSpecFetcher.new(specs:),
          sources: [rubygems_source.uri.to_s, github_source.uri.to_s]
        )

        resolved = client.resolve_dependency(Dependency.new(name: "cdc-orchestrator-pro", version: "0.1.0",
                                                            platform: "ruby"))

        assert_equal "https://rubygems.pkg.github.com/kanutocd", resolved.source
      end

      def test_download_gem_uses_resolved_source_and_direct_http_for_configured_private_sources
        Dir.mktmpdir do |dir|
          github_source = FakeSource.new("https://user:secret@rubygems.pkg.github.com/kanutocd/")
          specs = [
            [FakeSpec.new(name: "cdc-orchestrator-pro", version: Gem::Version.new("0.1.0"), platform: "ruby"),
             github_source]
          ]
          http = FakeHTTP.new(
            "/kanutocd/gems/cdc-orchestrator-pro-0.1.0.gem" => SuccessResponse.new("private-gem")
          )
          client = RubygemsClient.new(
            http:,
            spec_fetcher: FakeSpecFetcher.new(specs:),
            sources: [github_source.uri.to_s]
          )
          dependency = Dependency.new(name: "cdc-orchestrator-pro", version: "0.1.0", platform: "ruby",
                                      source: "https://rubygems.pkg.github.com/kanutocd/")
          destination = File.join(dir, "cdc-orchestrator-pro-0.1.0.gem")

          assert_equal destination, client.download_gem(dependency, destination)
          assert_equal "private-gem", File.binread(destination)
          assert_empty github_source.downloaded
        end
      end

      def test_download_gem_raises_when_dependency_source_does_not_match_any_configured_source
        github_source = FakeSource.new("https://rubygems.pkg.github.com/kanutocd/")
        specs = [[FakeSpec.new(name: "private-gem", version: Gem::Version.new("1.0.0"), platform: "ruby"), github_source]]
        client = RubygemsClient.new(spec_fetcher: FakeSpecFetcher.new(specs:), sources: [github_source.uri.to_s])
        dependency = Dependency.new(name: "private-gem", version: "1.0.0", platform: "ruby",
                                    source: "https://example.com/gems/")

        error = assert_raises(ArtifactFetchError) do
          client.download_gem(dependency, "/tmp/private-gem-1.0.0.gem")
        end

        assert_match(/No source found/, error.message)
      end


      def test_expected_sha256_falls_back_to_compact_index_for_private_sources
        github_source = FakeSource.new("https://rubygems.pkg.github.com/kanutocd/")
        http = FakeHTTP.new(
          "/kanutocd/api/v1/versions/cdc-orchestrator-pro.json" => FailureResponse.new("404", "Not Found"),
          "/kanutocd/info/cdc-orchestrator-pro" => SuccessResponse.new(<<~INFO)
            created_at: 2026-06-11T23:15:00Z
            ---
            0.1.0 cdc-concurrent:>= 0,cdc-parallel:>= 0|checksum:#{"D" * 64},ruby:>= 4.0.0
          INFO
        )
        client = RubygemsClient.new(
          http:,
          spec_fetcher: FakeSpecFetcher.new(specs: []),
          sources: [github_source.uri.to_s]
        )
        dependency = Dependency.new(name: "cdc-orchestrator-pro", version: "0.1.0", platform: "ruby",
                                    source: "https://rubygems.pkg.github.com/kanutocd/")

        assert_equal "d" * 64, client.expected_sha256(dependency)
      end

      def test_expected_sha256_falls_back_to_compact_index_for_native_platforms
        http = FakeHTTP.new(
          "/api/v1/versions/ffi.json" => FailureResponse.new("404", "Not Found"),
          "/info/ffi" => SuccessResponse.new(<<~INFO)
            ---
            1.17.4-x86_64-linux-gnu |checksum:#{"E" * 64}
            1.17.4-aarch64-linux-gnu |checksum:#{"F" * 64}
          INFO
        )
        client = RubygemsClient.new(http:)
        dependency = Dependency.new(name: "ffi", version: "1.17.4", platform: "x86_64-linux-gnu")

        assert_equal "e" * 64, client.expected_sha256(dependency)
      end

      def test_trusted_publishing_provenance_is_nil_for_non_rubygems_sources
        http = FakeHTTP.new({})
        client = RubygemsClient.new(http:)
        dependency = Dependency.new(name: "cdc-orchestrator-pro", version: "0.1.0", platform: "ruby",
                                    source: "https://rubygems.pkg.github.com/kanutocd/")

        assert_nil client.trusted_publishing_provenance(dependency)
        assert_empty http.requests
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
                          "number" => "1.0.0",
                          "platform" => ""
                        }
                      ])
          ),
          "/gems/sidekiq/versions/1.0.0" => SuccessResponse.new(
            "<html><body>Provenance: Built and signed on GitHub Actions "\
            "Build summary Source Commit kanutocd/sidekiq@a7edb75 "\
            "Build File .github/workflows/release.yml transparency log entry "\
            "https://example.test/log/123 SHA 256 checksum "\
            "be20cd051124b1a16cf97ea9157137abbd30a515c16a5ae9312d2eadd045e40f</body></html>"
          )
        )

        client = RubygemsClient.new(http:)
        provenance = client.trusted_publishing_provenance(Dependency.new(name: "sidekiq", version: "1.0.0", platform: "ruby"))

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
          ref: "refs/tags/v1.0.0",
          workflow: ".github/workflows/release.yml",
          build_summary_url: "https://rubygems.org/attestations/123"
        )

        http = FakeHTTP.new(
          "/api/v1/versions/sidekiq.json" => SuccessResponse.new(
            JSON.dump([
                        {
                          "number" => "1.0.0",
                          "platform" => ""
                        }
                      ])
          ),
          "/api/v1/attestations/sidekiq-1.0.0.json" => SuccessResponse.new(
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
        provenance = client.trusted_publishing_provenance(Dependency.new(name: "sidekiq", version: "1.0.0", platform: "ruby"))

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

      def test_trusted_publishing_provenance_finds_deeply_nested_payload
        http = FakeHTTP.new(
          "/api/v1/versions/activesupport.json" => SuccessResponse.new(
            JSON.dump([
                        {
                          "number" => "8.0.0",
                          "platform" => "",
                          "trusted_publishing" => "true",
                          "provenance" => "signed",
                          "payload" => [
                            { "ignore" => "me" },
                            {
                              "source_repository" => "ruby/activesupport",
                              "source_commit" => "ruby/activesupport@abc123",
                              "workflow_name" => "release.yml",
                              "digest" => "f" * 64,
                              "transparency_log_entry" => "https://example.test/log/123"
                            }
                          ]
                        }
                      ])
          )
        )

        client = RubygemsClient.new(http:)
        provenance = client.trusted_publishing_provenance(Dependency.new(name: "activesupport", version: "8.0.0",
                                                                         platform: "ruby"))

        refute_nil provenance
        assert(provenance.trusted_publishing)
        assert_equal "ruby/activesupport", provenance.repository
        assert_equal "ruby/activesupport@abc123", provenance.ref
        assert_equal "release.yml", provenance.workflow
        assert_equal "https://example.test/log/123", provenance.attestation_url
        assert_equal "f" * 64, provenance.sha256
      end

      def test_trusted_publishing_provenance_returns_nil_when_html_has_no_provenance_markers
        http = FakeHTTP.new(
          "/api/v1/versions/nope.json" => SuccessResponse.new(
            JSON.dump([
                        {
                          "number" => "1.0.0",
                          "platform" => ""
                        }
                      ])
          ),
          "/gems/nope/versions/1.0.0" => SuccessResponse.new("<html><body>No provenance here</body></html>")
        )

        client = RubygemsClient.new(http:)

        assert_nil client.trusted_publishing_provenance(Dependency.new(name: "nope", version: "1.0.0", platform: "ruby"))
      end

      def test_trusted_publishing_provenance_returns_nil_when_attestation_has_no_certificate
        http = FakeHTTP.new(
          "/api/v1/versions/nope.json" => SuccessResponse.new(
            JSON.dump([
                        {
                          "number" => "1.0.0",
                          "platform" => ""
                        }
                      ])
          ),
          "/api/v1/attestations/nope-1.0.0.json" => SuccessResponse.new(JSON.dump([{}])),
          "/gems/nope/versions/1.0.0" => SuccessResponse.new("<html><body>No provenance here</body></html>")
        )

        client = RubygemsClient.new(http:)

        assert_nil client.trusted_publishing_provenance(Dependency.new(name: "nope", version: "1.0.0", platform: "ruby"))
      end

      def test_private_helpers_cover_blank_http_and_mismatch_paths
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        assert_equal [nil, nil], client.send(:parse_source_commit, "")
        assert_equal "https://example.com/ruby/rake",
                     client.send(:normalize_repository, "https://example.com/ruby/rake")
        assert_nil client.send(:build_file_from_subject_alt_name,
                               "URI:https://github.com/ruby/rake/.github/workflows/release.yml@refs/tags/v13.2.1",
                               "ruby/rake", "refs/tags/v13.2.2")
        refute client.send(:provenance_hash?, { "foo" => "bar" })
      end

      def test_parse_attestation_certificate_handles_certificate_object_without_relevant_extensions
        client = RubygemsClient.new(http: FakeHTTP.new({}))
        certificate = build_blank_certificate

        assert_nil client.send(:parse_attestation_certificate, certificate)
      end



      def test_resolve_dependency_returns_dependency_when_source_is_already_present
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby", source: "https://rubygems.org")
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        assert_same dependency, client.resolve_dependency(dependency)
      end

      def test_resolve_dependency_returns_original_when_resolution_fails
        dependency = Dependency.new(name: "missing", version: "0.0.1", platform: "ruby")
        client = RubygemsClient.new(spec_fetcher: FakeSpecFetcher.new(specs: []))

        assert_same dependency, client.resolve_dependency(dependency)
      end

      def test_private_source_and_platform_helpers_cover_edge_cases
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        refute client.send(:source_matches?, "https://rubygems.org", "https://example.com")
        assert client.send(:platform_matches?, "", "")
        assert_equal "https://rubygems.org", client.send(:comparable_source_uri, "https://user:secret@rubygems.org/")
        assert_equal "https://rubygems.org", client.send(:host_for, Dependency.new(name: "rake", version: "13.2.1", platform: "ruby"))
      end

      def test_spec_full_name_builds_native_names_when_full_name_is_unavailable
        client = RubygemsClient.new(http: FakeHTTP.new({}))
        native_spec = FakeSpec.new(name: "nokogiri", version: Gem::Version.new("1.18.9"), platform: "x86_64-linux")
        ruby_spec = FakeSpec.new(name: "rake", version: Gem::Version.new("13.2.1"), platform: "ruby")

        assert_equal "nokogiri-1.18.9-x86_64-linux", client.send(:spec_full_name, native_spec)
        assert_equal "rake-13.2.1", client.send(:spec_full_name, ruby_spec)
      end

      def test_gem_uri_handles_sources_without_trailing_slash
        client = RubygemsClient.new(http: FakeHTTP.new({}))
        spec = FakeSpec.new(name: "rake", version: Gem::Version.new("13.2.1"), platform: "ruby")

        uri = client.send(:gem_uri, "https://rubygems.org", spec)

        assert_equal "https://rubygems.org/gems/rake-13.2.1.gem", uri.to_s
      end

      def test_warn_ambiguous_sources_is_quiet_for_same_sanitized_source
        client = RubygemsClient.new(http: FakeHTTP.new({}))
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
        source = FakeSource.new("https://rubygems.org/")
        spec = fake_spec(name: "rake", version: "13.2.1")
        err = capture_io do
          client.send(:warn_ambiguous_sources, dependency, [[spec, source], [spec, source]])
        end.last

        assert_empty err
      end

      def test_source_order_returns_configured_size_for_unknown_sources
        configured = FakeSource.new("https://rubygems.org/")
        unknown = FakeSource.new("https://example.com/")
        client = RubygemsClient.new(http: FakeHTTP.new({}), sources: [configured.uri.to_s])

        assert_equal 1, client.send(:source_order, unknown)
      end

      def test_find_certificate_returns_nil_for_non_matching_values
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        assert_nil client.send(:find_certificate, "not a certificate")
        assert_nil client.send(:find_certificate, { "nested" => ["still not a certificate"] })
        assert_nil client.send(:find_certificate, Object.new)
      end

      def test_find_certificate_finds_nested_certificate_strings
        client = RubygemsClient.new(http: FakeHTTP.new({}))
        pem = "-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----"

        assert_equal pem, client.send(:find_certificate, { "bundle" => ["ignore", { "leaf" => pem }] })
      end

      def test_html_provenance_payload_defaults_workflow_when_build_file_only_is_present
        client = RubygemsClient.new(http: FakeHTTP.new({}))
        payload = client.send(:html_provenance_payload, "Build File .github/workflows/release.yml")

        assert_equal "GitHub Actions", payload[:workflow]
      end

      def test_html_provenance_payload_returns_nil_when_no_markers_exist
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        assert_nil client.send(:html_provenance_payload, "plain page")
      end

      def test_attestation_bundle_provenance_handles_json_string_payloads_without_certificate
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        assert_nil client.send(:attestation_bundle_provenance, JSON.dump({ "bundle" => [] }))
      end

      def test_build_file_from_subject_alt_name_returns_nil_for_blank_inputs
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        assert_nil client.send(:build_file_from_subject_alt_name, nil, "ruby/rake", "refs/tags/v1")
      end

      def test_normalize_repository_returns_nil_for_blank_repository
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        assert_nil client.send(:normalize_repository, nil)
      end

      def test_parse_source_commit_preserves_http_repository
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        assert_equal ["https://example.com/repo", "abc"], client.send(:parse_source_commit, "https://example.com/repo@abc")
      end

      def test_deep_find_provenance_hash_returns_nil_for_unknown_values
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        assert_nil client.send(:deep_find_provenance_hash, [1, { "x" => "y" }])
      end

      def test_trusted_publishing_flag_handles_falsey_and_string_values
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        assert client.send(:trusted_publishing_flag?, { "trusted_publishing" => "TRUE" })
        refute client.send(:trusted_publishing_flag?, { "trusted_publishing" => false })
      end

      def test_get_raises_for_http_error
        client = RubygemsClient.new(http: FakeHTTP.new("/api/v1/versions/rake.json" => FailureResponse.new("500", "Boom")))

        error = assert_raises(Error) { client.send(:get, "/api/v1/versions/rake.json") }

        assert_match(/500 Boom/, error.message)
      end

      def test_get_response_raises_for_too_many_redirects_and_missing_location
        client = RubygemsClient.new(http: FakeHTTP.new("/loop" => RedirectResponse.new(nil)))

        assert_raises(Error) { client.send(:get_response, URI("https://rubygems.org/loop"), limit: -1) }
        assert_raises(Error) { client.send(:get_response, URI("https://rubygems.org/loop")) }
      end

      def test_authorization_headers_cover_non_github_embedded_and_missing_credentials
        github_uri = URI("https://user:embedded@rubygems.pkg.github.com/kanutocd/gems/private-1.0.0.gem")
        public_uri = URI("https://rubygems.org/gems/rake-13.2.1.gem")
        client = RubygemsClient.new(http: FakeHTTP.new({}), credentials: FakeCredentials.new(nil))

        assert_equal({}, client.send(:authorization_headers, public_uri))
        assert_equal({ "Authorization" => "Bearer embedded" }, client.send(:authorization_headers, github_uri))
        assert_nil client.send(:bearer_token_for, URI("https://rubygems.pkg.github.com/kanutocd/gems/private-1.0.0.gem"))
      end

      def test_authenticated_response_uses_injected_http_when_it_supports_request
        http = FakeHTTP.new("/kanutocd/gems/private-1.0.0.gem" => SuccessResponse.new("private"))
        client = RubygemsClient.new(http:, credentials: FakeCredentials.new("user:token"))

        response = client.send(:get_response, URI("https://rubygems.pkg.github.com/kanutocd/gems/private-1.0.0.gem"))

        assert_equal "private", response.body
        assert_equal ["Bearer token"], http.requests.first.last["authorization"]
      end



      def test_registry_checksum_uses_first_successful_provider_after_failure
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
        failing_provider = Object.new
        def failing_provider.checksum_for(_dependency, client:) = raise "boom"
        successful_provider = Object.new
        def successful_provider.checksum_for(_dependency, client:)
          ChecksumProvider::Result.new(
            sha256: "1" * 64,
            source: :registry,
            provider: "test-provider",
            verification_uri: "https://example.test/checksum"
          )
        end

        client = RubygemsClient.new(checksum_providers: [failing_provider, successful_provider])
        result = client.registry_checksum(dependency)

        assert_equal "1" * 64, result.sha256
        assert_equal "test-provider", result.provider
      end

      def test_registry_checksum_returns_nil_when_all_providers_fail_or_return_nil
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
        nil_provider = Object.new
        def nil_provider.checksum_for(_dependency, client:) = nil
        failing_provider = Object.new
        def failing_provider.checksum_for(_dependency, client:) = raise "boom"

        client = RubygemsClient.new(checksum_providers: [nil_provider, failing_provider])

        assert_nil client.registry_checksum(dependency)
      end

      def test_rubygems_api_checksum_returns_nil_when_matching_version_has_no_checksum
        http = FakeHTTP.new(
          "/api/v1/versions/rake.json" => SuccessResponse.new(
            JSON.dump([{ "number" => "13.2.1", "platform" => "ruby", "sha" => nil }])
          )
        )
        client = RubygemsClient.new(http:)
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")

        assert_nil client.rubygems_api_checksum(dependency)
      end

      def test_compact_index_registry_checksum_returns_nil_when_no_matching_checksum_exists
        http = FakeHTTP.new(
          "/api/v1/versions/rake.json" => FailureResponse.new("404", "Not Found"),
          "/info/rake" => SuccessResponse.new(<<~INFO)
            created_at: 2026-01-01T00:00:00Z
            ---

            13.2.1 dependencies:>= 0
            13.2.2 |checksum:#{"A" * 64}
          INFO
        )
        client = RubygemsClient.new(http:)
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")

        assert_nil client.compact_index_registry_checksum(dependency)
      end

      def test_matching_specs_orders_sources_by_configured_source_list
        first_source = FakeSource.new("https://first.example/")
        second_source = FakeSource.new("https://second.example/")
        spec = fake_spec(name: "rake", version: "13.2.1")
        client = RubygemsClient.new(
          spec_fetcher: FakeSpecFetcher.new(specs: [[spec, second_source], [spec, first_source]]),
          sources: [first_source.uri.to_s, second_source.uri.to_s]
        )
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")

        matches = client.send(:matching_specs, dependency)

        assert_equal [first_source, second_source], matches.map(&:last)
      end

      def test_warn_ambiguous_sources_prints_when_multiple_sanitized_sources_exist
        client = RubygemsClient.new(http: FakeHTTP.new({}))
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
        spec = fake_spec(name: "rake", version: "13.2.1")
        first_source = FakeSource.new("https://rubygems.org/")
        second_source = FakeSource.new("https://mirror.example/")

        _out, err = capture_io do
          client.send(:warn_ambiguous_sources, dependency, [[spec, first_source], [spec, second_source]])
        end

        assert_match(/found in multiple sources/, err)
        assert_match(/using https:\/\/rubygems.org/, err)
      end

      def test_spec_full_name_omits_blank_platform_when_full_name_is_unavailable
        client = RubygemsClient.new(http: FakeHTTP.new({}))
        spec = FakeSpec.new(name: "rake", version: Gem::Version.new("13.2.1"), platform: "")

        assert_equal "rake-13.2.1", client.send(:spec_full_name, spec)
      end

      def test_provenance_payload_uses_version_hash_when_trusted_publishing_flag_is_true
        client = RubygemsClient.new(http: FakeHTTP.new({}))
        version = {
          "number" => "13.2.1",
          "platform" => "ruby",
          "trusted_publishing" => true,
          "repository" => "https://github.com/ruby/rake",
          "workflow" => "release.yml"
        }

        payload = client.send(:provenance_payload, version)

        assert_equal "https://github.com/ruby/rake", payload["repository"]
        assert_equal "release.yml", payload["workflow"]
      end

      def test_attestation_bundle_provenance_accepts_hash_payloads_without_certificate
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        assert_nil client.send(:attestation_bundle_provenance, { "bundle" => [] })
      end

      def test_parse_attestation_certificate_returns_nil_for_invalid_certificate_payload
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        assert_nil client.send(:parse_attestation_certificate, "not a certificate")
      end

      def test_build_file_from_subject_alt_name_extracts_matching_workflow_path
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        assert_equal ".github/workflows/release.yml",
                     client.send(:build_file_from_subject_alt_name,
                                 "URI:https://github.com/ruby/rake/.github/workflows/release.yml@refs/tags/v13.2.1",
                                 "ruby/rake", "refs/tags/v13.2.1")
      end

      def test_capture_text_returns_nil_when_pattern_does_not_match
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        assert_nil client.send(:capture_text, "plain text", /missing (.+)/)
      end

      def test_trusted_publishing_flag_handles_missing_value
        client = RubygemsClient.new(http: FakeHTTP.new({}))

        refute client.send(:trusted_publishing_flag?, {})
      end


      def test_resolve_dependency_returns_original_when_source_is_already_present
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby", source: "https://rubygems.org")
        client = RubygemsClient.new

        assert_same dependency, client.resolve_dependency(dependency)
      end

      def test_registry_checksum_skips_provider_errors_and_uses_next_provider
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
        bad_provider = Object.new
        def bad_provider.checksum_for(_dependency, client:)
          raise "boom"
        end
        good_provider = Object.new
        def good_provider.checksum_for(_dependency, client:)
          ChecksumProvider::Result.new(
            sha256: "1" * 64,
            source: :registry,
            provider: "fallback-provider",
            verification_uri: "https://example.test/checksum"
          )
        end
        client = RubygemsClient.new(checksum_providers: [bad_provider, good_provider])

        result = client.registry_checksum(dependency)

        assert_equal "1" * 64, result.sha256
        assert_equal "fallback-provider", result.provider
      end

      def test_compact_index_registry_checksum_returns_nil_when_checksum_is_missing
        http = FakeHTTP.new(
          "/info/rake" => SuccessResponse.new("---\n13.2.1 |checksum:\n")
        )
        client = RubygemsClient.new(http:)
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")

        assert_nil client.compact_index_registry_checksum(dependency)
      end

      def test_compact_index_registry_checksum_supports_native_platforms
        sha = "2" * 64
        http = FakeHTTP.new(
          "/info/nokogiri" => SuccessResponse.new("---\n1.18.9-x86_64-linux |checksum:#{sha},ruby:>= 3.1\n")
        )
        client = RubygemsClient.new(http:)
        dependency = Dependency.new(name: "nokogiri", version: "1.18.9", platform: "x86_64-linux")

        result = client.compact_index_registry_checksum(dependency)

        assert_equal sha, result.sha256
        assert_equal "compact-index", result.provider
      end

      def test_get_response_raises_after_too_many_redirects
        client = RubygemsClient.new
        error = assert_raises(Error) do
          client.send(:get_response, URI("https://rubygems.org/gems/rake.gem"), limit: -1)
        end

        assert_match(/Too many redirects/, error.message)
      end

      def test_redirect_response_raises_when_location_is_missing
        response = RedirectResponse.new(nil)
        client = RubygemsClient.new

        error = assert_raises(Error) do
          client.send(:redirect_response, response, URI("https://rubygems.org/gems/rake.gem"), 5)
        end

        assert_match(/Redirect missing location/, error.message)
      end

      def test_authorization_headers_are_empty_for_non_github_hosts
        client = RubygemsClient.new

        assert_empty client.send(:authorization_headers, URI("https://rubygems.org/gems/rake.gem"))
      end

      def test_authorization_headers_are_empty_when_github_credentials_are_missing
        client = RubygemsClient.new(credentials: FakeCredentials.new(nil))

        assert_empty client.send(:authorization_headers, URI("https://rubygems.pkg.github.com/kanutocd/gems/private.gem"))
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

      def build_blank_certificate
        key = OpenSSL::PKey::RSA.new(2048)
        cert = OpenSSL::X509::Certificate.new
        cert.version = 2
        cert.serial = 2
        cert.subject = OpenSSL::X509::Name.parse("/CN=Sigstore Test")
        cert.issuer = cert.subject
        cert.public_key = key.public_key
        cert.not_before = Time.now - 60
        cert.not_after = Time.now + 3600
        cert.sign(key, OpenSSL::Digest.new("SHA256"))
        cert
      end
    end
    # rubocop:enable Metrics/ClassLength, Metrics/AbcSize, Metrics/MethodLength, Layout/LineLength,
    #                Minitest/AssertTruthy
  end
end
