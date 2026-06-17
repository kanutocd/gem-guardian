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

      def test_provenance_status_reports_unsupported_for_non_trusted_publishing_records
        verifier = ProvenanceVerifier.new(client: FakeClient.new(nil))
        record = ProvenanceRecord.new(
          trusted_publishing: false,
          repository: nil,
          ref: nil,
          workflow: nil,
          issuer: nil,
          subject: nil,
          sha256: nil,
          attestation_url: nil
        )

        assert_equal :unsupported, verifier.send(:provenance_status, record, "a" * 64)
      end

      def test_secure_compare_rejects_different_length_values
        verifier = ProvenanceVerifier.new(client: FakeClient.new(nil))

        refute verifier.send(:secure_compare, "abc", "de")
      end

      def test_combine_status_prefers_github_mismatch_and_error
        verifier = ProvenanceVerifier.new(client: FakeClient.new(nil))

        assert_equal :mismatch, verifier.send(:combine_status, :verified, :mismatch)
        assert_equal :error, verifier.send(:combine_status, :verified, :error)
        assert_equal :verified, verifier.send(:combine_status, :verified, :verified)
        assert_equal :unsupported, verifier.send(:combine_status, :unsupported, nil)
      end

      def test_github_release_result_rescues_errors
        client = FakeClient.new(
          ProvenanceRecord.new(
            trusted_publishing: true,
            repository: "https://github.com/ruby/rake",
            ref: "refs/tags/v13.2.1",
            workflow: "release.yml",
            issuer: "https://token.actions.githubusercontent.com",
            subject: "repo:ruby/rake:ref:refs/tags/v13.2.1",
            sha256: "a" * 64,
            attestation_url: "https://rubygems.org"
          )
        )
        verifier = ProvenanceVerifier.new(
          client:,
          github_release_verifier: Class.new do
            def verify(_provenance)
              raise Error, "boom"
            end
          end.new
        )

        result = verifier.verify(Dependency.new(name: "rake", version: "13.2.1", platform: "ruby"),
                                artifact_sha256: "a" * 64)

        assert_equal :verified, result.status
        assert_nil result.github_release
      end


      def test_provenance_status_is_verified_when_artifact_sha_is_missing
        verifier = ProvenanceVerifier.new(client: FakeClient.new(nil))
        record = ProvenanceRecord.new(
          trusted_publishing: true,
          repository: nil,
          ref: nil,
          workflow: nil,
          issuer: nil,
          subject: nil,
          sha256: "a" * 64,
          attestation_url: nil
        )

        assert_equal :verified, verifier.send(:provenance_status, record, nil)
      end

      def test_combine_status_uses_github_status_when_provenance_is_unsupported
        verifier = ProvenanceVerifier.new(client: FakeClient.new(nil))

        assert_equal :verified, verifier.send(:combine_status, :unsupported, :verified)
      end
    end
  end
end
