# frozen_string_literal: true

require_relative "../../test_helper"

module Gem
  module Guardian
    class RegistryAuditTest < Minitest::Test
      FakeProvenance = Data.define(:dependency, :status, :trusted_publishing, :repository, :ref, :workflow, :issuer,
                                   :subject, :expected_sha256, :actual_sha256, :error, :attestation_url,
                                   :github_release)

      class FakeRegistry
        def initialize(entries)
          @entries = entries
        end

        def each_latest_spec(limit: nil)
          selected = limit ? @entries.first(limit) : @entries
          return selected.each unless block_given?

          selected.each { |entry| yield entry }
        end
      end

      class FakeProvenanceVerifier
        def verify(dependency)
          status = dependency.name == "trusted" ? :verified : :unsupported
          FakeProvenance.new(
            dependency:,
            status:,
            trusted_publishing: status == :verified,
            repository: nil,
            ref: nil,
            workflow: nil,
            issuer: nil,
            subject: nil,
            expected_sha256: nil,
            actual_sha256: nil,
            error: nil,
            attestation_url: nil,
            github_release: nil
          )
        end
      end

      def test_run_groups_provenance_statuses
        entries = [
          Registry::Entry.new(name: "trusted", version: "1.0.0", platform: "ruby", source: "https://rubygems.org"),
          Registry::Entry.new(name: "legacy", version: "1.0.0", platform: "ruby", source: "https://rubygems.org")
        ]

        result = RegistryAudit.new(
          registry: FakeRegistry.new(entries),
          provenance_verifier: FakeProvenanceVerifier.new
        ).run

        assert_equal 2, result.total
        assert_equal 1, result.counts.fetch(:verified)
        assert_equal 1, result.counts.fetch(:unsupported)
        assert_equal ["trusted"], result.verified.map { |entry_result| entry_result.dependency.name }
        assert_equal ["legacy"], result.unsupported.map { |entry_result| entry_result.dependency.name }
        assert_empty result.errors
        assert_empty result.mismatches
      end

      def test_run_honors_limit
        entries = [
          Registry::Entry.new(name: "trusted", version: "1.0.0", platform: "ruby", source: "https://rubygems.org"),
          Registry::Entry.new(name: "legacy", version: "1.0.0", platform: "ruby", source: "https://rubygems.org")
        ]

        result = RegistryAudit.new(
          registry: FakeRegistry.new(entries),
          provenance_verifier: FakeProvenanceVerifier.new
        ).run(limit: 1)

        assert_equal 1, result.total
        assert_equal ["trusted"], result.results.map { |entry_result| entry_result.dependency.name }
      end
    end
  end
end
