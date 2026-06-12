# frozen_string_literal: true

require_relative "../../test_helper"

module Gem
  module Guardian
    class ProvenanceVerifierTest < Minitest::Test
      ProvenanceRecord = RubygemsClient::TrustedPublishingProvenance

      class FakeClient
        def initialize(record)
          @record = record
        end

        def trusted_publishing_provenance(_dependency)
          @record
        end
      end

      def test_verify_passes_when_provenance_matches_artifact_sha
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
        record = ProvenanceRecord.new(
          trusted_publishing: true,
          repository: "https://github.com/ruby/rake",
          ref: "refs/tags/v13.2.1",
          workflow: "release.yml",
          issuer: "https://token.actions.githubusercontent.com",
          subject: "repo:ruby/rake:ref:refs/tags/v13.2.1",
          sha256: "a" * 64,
          attestation_url: "https://rubygems.org"
        )

        result = ProvenanceVerifier.new(client: FakeClient.new(record)).verify(dependency, artifact_sha256: "a" * 64)

        assert_equal :verified, result.status
        assert_equal "https://github.com/ruby/rake", result.repository
        assert_equal "a" * 64, result.expected_sha256
      end

      def test_verify_reports_mismatch_when_sha_differs
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
        record = ProvenanceRecord.new(
          trusted_publishing: true,
          repository: "https://github.com/ruby/rake",
          ref: "refs/tags/v13.2.1",
          workflow: "release.yml",
          issuer: "https://token.actions.githubusercontent.com",
          subject: "repo:ruby/rake:ref:refs/tags/v13.2.1",
          sha256: "a" * 64,
          attestation_url: "https://rubygems.org"
        )

        result = ProvenanceVerifier.new(client: FakeClient.new(record)).verify(dependency, artifact_sha256: "b" * 64)

        assert_equal :mismatch, result.status
        assert_equal "a" * 64, result.expected_sha256
        assert_equal "b" * 64, result.actual_sha256
      end

      def test_verify_passes_when_trusted_publishing_has_no_provenance_checksum
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
        record = ProvenanceRecord.new(
          trusted_publishing: true,
          repository: "https://github.com/ruby/rake",
          ref: "refs/tags/v13.2.1",
          workflow: "release.yml",
          issuer: "https://token.actions.githubusercontent.com",
          subject: "repo:ruby/rake:ref:refs/tags/v13.2.1",
          sha256: nil,
          attestation_url: "https://rubygems.org"
        )

        result = ProvenanceVerifier.new(client: FakeClient.new(record)).verify(dependency, artifact_sha256: "a" * 64)

        assert_equal :verified, result.status
        assert_nil result.expected_sha256
      end

      def test_verify_reports_unsupported_when_record_is_not_trusted_publishing
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
        record = ProvenanceRecord.new(
          trusted_publishing: false,
          repository: "https://github.com/ruby/rake",
          ref: "refs/tags/v13.2.1",
          workflow: "release.yml",
          issuer: "https://token.actions.githubusercontent.com",
          subject: "repo:ruby/rake:ref:refs/tags/v13.2.1",
          sha256: "a" * 64,
          attestation_url: "https://rubygems.org"
        )

        result = ProvenanceVerifier.new(client: FakeClient.new(record)).verify(dependency, artifact_sha256: "a" * 64)

        assert_equal :unsupported, result.status
      end

      def test_verify_reports_unsupported_when_no_provenance_record_exists
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")

        result = ProvenanceVerifier.new(client: FakeClient.new(nil)).verify(dependency, artifact_sha256: "a" * 64)

        assert_equal :unsupported, result.status
        assert_nil result.expected_sha256
      end
    end
  end
end
