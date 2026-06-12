# frozen_string_literal: true

require "json"

require_relative "../../test_helper"

module Gem
  module Guardian
    class GitHubReleaseVerifierTest < Minitest::Test
      SuccessResponse = Struct.new(:body) do
        def is_a?(klass)
          klass == Net::HTTPSuccess || super
        end
      end

      class FakeHTTP
        def initialize(response_map)
          @response_map = response_map
        end

        def get_response(uri)
          @response_map.fetch(uri.path)
        end
      end

      def test_verify_discovers_release_assets_and_passes_signed_release
        http = FakeHTTP.new(
          "/repos/kanutocd/gem-guardian/releases/tags/v0.1.1" => SuccessResponse.new(
            JSON.dump(
              "html_url" => "https://github.com/kanutocd/gem-guardian/releases/tag/v0.1.1",
              "assets" => [
                { "name" => "gem-guardian-0.1.1.gem.sha256" },
                { "name" => "gem-guardian-0.1.1.gem.sig" },
                { "name" => "notes.txt" }
              ],
              "attestations" => [{ "url" => "https://github.com/kanutocd/gem-guardian/releases/attestation/1" }]
            )
          ),
          "/repos/kanutocd/gem-guardian/git/ref/tags/v0.1.1" => SuccessResponse.new(
            JSON.dump(
              "object" => {
                "type" => "tag",
                "verification" => { "verified" => true, "reason" => "valid" }
              }
            )
          )
        )

        verifier = GitHubReleaseVerifier.new(client: GitHubClient.new(http:))
        provenance = build_provenance
        result = verifier.verify(provenance)

        assert_equal :verified, result.status
        assert_equal "kanutocd/gem-guardian", result.repository
        assert_equal "v0.1.1", result.tag
        assert_equal ["gem-guardian-0.1.1.gem.sha256"], result.checksum_assets
        assert_equal ["gem-guardian-0.1.1.gem.sig"], result.signature_assets
        assert_equal true, result.signed_tag
        assert_equal true, result.release_attestation
      end

      def test_verify_reports_unsupported_for_non_github_repositories
        verifier = GitHubReleaseVerifier.new(client: GitHubClient.new(http: FakeHTTP.new({})))

        result = verifier.verify(build_provenance(repository: "https://example.com/kanutocd/gem-guardian"))

        assert_equal :unsupported, result.status
      end

      def test_verify_reports_mismatch_for_unsigned_tags
        http = FakeHTTP.new(
          "/repos/kanutocd/gem-guardian/releases/tags/v0.1.1" => SuccessResponse.new(
            JSON.dump(
              "html_url" => "https://github.com/kanutocd/gem-guardian/releases/tag/v0.1.1",
              "assets" => [],
              "attestations" => [{ "url" => "https://github.com/kanutocd/gem-guardian/releases/attestation/1" }]
            )
          ),
          "/repos/kanutocd/gem-guardian/git/ref/tags/v0.1.1" => SuccessResponse.new(
            JSON.dump(
              "object" => {
                "type" => "tag",
                "verification" => { "verified" => false, "reason" => "unsigned" }
              }
            )
          )
        )

        verifier = GitHubReleaseVerifier.new(client: GitHubClient.new(http:))
        result = verifier.verify(build_provenance)

        assert_equal :mismatch, result.status
        assert_equal false, result.signed_tag
      end

      def test_verify_reports_error_for_invalid_release_attestation
        http = FakeHTTP.new(
          "/repos/kanutocd/gem-guardian/releases/tags/v0.1.1" => SuccessResponse.new(
            JSON.dump(
              "html_url" => "https://github.com/kanutocd/gem-guardian/releases/tag/v0.1.1",
              "assets" => [],
              "attestation" => true
            )
          ),
          "/repos/kanutocd/gem-guardian/git/ref/tags/v0.1.1" => SuccessResponse.new(
            JSON.dump(
              "object" => {
                "type" => "tag",
                "verification" => { "verified" => true, "reason" => "invalid" }
              }
            )
          )
        )

        verifier = GitHubReleaseVerifier.new(client: GitHubClient.new(http:))
        result = verifier.verify(build_provenance)

        assert_equal :error, result.status
      end

      def test_verify_returns_unsupported_when_release_is_missing
        http = FakeHTTP.new(
          "/repos/kanutocd/gem-guardian/releases/tags/v0.1.1" => Struct.new(:code, :message).new("404", "Not Found"),
          "/repos/kanutocd/gem-guardian/releases/tags/0.1.1" => Struct.new(:code, :message).new("404", "Not Found")
        )

        verifier = GitHubReleaseVerifier.new(client: GitHubClient.new(http:))
        result = verifier.verify(build_provenance(ref: "a7edb75", subject: "kanutocd/gem-guardian@a7edb75"))

        assert_equal :unsupported, result.status
      end

      def test_verify_falls_back_to_version_tag_when_provenance_only_has_commit_sha
        http = FakeHTTP.new(
          "/repos/kanutocd/gem-guardian/releases/tags/v0.1.1" => SuccessResponse.new(
            JSON.dump(
              "html_url" => "https://github.com/kanutocd/gem-guardian/releases/tag/v0.1.1",
              "assets" => [
                { "name" => "gem-guardian-0.1.1.gem.sha256" },
                { "name" => "gem-guardian-0.1.1.gem.sig" }
              ],
              "attestations" => [{ "url" => "https://github.com/kanutocd/gem-guardian/releases/attestation/1" }]
            )
          ),
          "/repos/kanutocd/gem-guardian/git/ref/tags/v0.1.1" => SuccessResponse.new(
            JSON.dump(
              "object" => {
                "type" => "tag",
                "verification" => { "verified" => true, "reason" => "valid" }
              }
            )
          )
        )

        verifier = GitHubReleaseVerifier.new(client: GitHubClient.new(http:))
        result = verifier.verify(build_provenance(ref: "a7edb75", subject: "kanutocd/gem-guardian@a7edb75"))

        assert_equal :verified, result.status
        assert_equal "v0.1.1", result.tag
        assert_equal ["gem-guardian-0.1.1.gem.sha256"], result.checksum_assets
        assert_equal ["gem-guardian-0.1.1.gem.sig"], result.signature_assets
      end

      def test_private_helpers_cover_repository_tag_and_asset_matching
        verifier = GitHubReleaseVerifier.new(client: GitHubClient.new(http: FakeHTTP.new({})))
        provenance = build_provenance(repository: "kanutocd/gem-guardian")

        assert_equal "kanutocd/gem-guardian", verifier.send(:github_repository, "https://github.com/kanutocd/gem-guardian")
        assert_equal "kanutocd/gem-guardian", verifier.send(:github_repository, "kanutocd/gem-guardian")
        assert_nil verifier.send(:github_repository, nil)
        assert_equal "v0.1.1", verifier.send(:github_tag, provenance)
        assert_includes verifier.send(:github_tag_candidates, build_provenance(repository: "https://github.com/kanutocd/gem-guardian",
                                                                              ref: "abc123",
                                                                              subject: "no tag here")), "v0.1.1"

        matcher = verifier.send(:checksum_asset_name?)
        assert matcher.call("gem-guardian-0.1.1.gem.sha256")
        refute matcher.call("gem-guardian-0.1.1.gem.sig")
        assets = verifier.send(:discovered_assets, { "assets" => [{ "name" => "a.sha256" }, "b.sig", { "name" => "c.txt" }] },
                               matcher)
        assert_equal ["a.sha256"], assets
      end

      def test_private_helpers_cover_release_status_variants
        verifier = GitHubReleaseVerifier.new(client: GitHubClient.new(http: FakeHTTP.new({})))

        assert_equal :verified, verifier.send(:release_status, true, true, { "verified" => true })
        assert_equal :mismatch, verifier.send(:release_status, false, true, { "verified" => false })
        assert_equal :mismatch, verifier.send(:release_status, nil, false, nil)
        assert_equal :unsupported, verifier.send(:release_status, nil, nil, nil)
      end

      def test_private_helper_covers_release_attestation_nil
        verifier = GitHubReleaseVerifier.new(client: GitHubClient.new(http: FakeHTTP.new({})))

        assert_nil verifier.send(:release_attestation, { "html_url" => "https://github.com/kanutocd/gem-guardian/releases/tag/v0.1.1" })
      end

      private

      def build_provenance(repository: "https://github.com/kanutocd/gem-guardian",
                           ref: "refs/tags/v0.1.1",
                           subject: "kanutocd/gem-guardian@562299f")
        ProvenanceResult.new(
          dependency: Dependency.new(name: "gem-guardian", version: "0.1.1", platform: "ruby"),
          status: :verified,
          trusted_publishing: true,
          repository:,
          ref:,
          workflow: "GitHub Actions",
          issuer: "https://token.actions.githubusercontent.com",
          subject:,
          expected_sha256: "a" * 64,
          actual_sha256: "a" * 64,
          error: nil,
          attestation_url: "https://rubygems.org",
          github_release: nil
        )
      end
    end
  end
end
