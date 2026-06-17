# frozen_string_literal: true

module Gem
  module Guardian
    # Result object for a provenance verification attempt.
    ProvenanceResult = Data.define(
      :dependency, :status, :trusted_publishing, :repository, :ref, :workflow, :issuer, :subject,
      :expected_sha256, :actual_sha256, :error, :attestation_url, :github_release
    ) do
      # Returns true when provenance verification succeeded.
      def verified?
        status == :verified
      end
    end

    # Verifies RubyGems Trusted Publishing provenance metadata.
    class ProvenanceVerifier
      def initialize(client: RubygemsClient.new, github_release_verifier: GitHubReleaseVerifier.new)
        @client = client
        @github_release_verifier = github_release_verifier
      end

      # Verifies Trusted Publishing provenance for +dependency+.
      def verify(dependency, artifact_sha256: nil)
        provenance = @client.trusted_publishing_provenance(dependency)
        return unsupported_result(dependency) unless provenance

        build_result(dependency, provenance, artifact_sha256)
      rescue StandardError => e
        error_result(dependency, artifact_sha256, e)
      end

      # Verifies provenance for each dependency-result pair.
      def verify_all(results)
        results.map { |result| verify(result.dependency, artifact_sha256: result.actual_sha256) }
      end

      private

      def build_result(dependency, provenance, artifact_sha256)
        github_release = github_release_result(provenance)
        status = combine_status(provenance_status(provenance, artifact_sha256), github_release&.status)
        ProvenanceResult.new(**result_attributes(dependency, provenance, artifact_sha256, status, github_release))
      end

      def unsupported_result(dependency)
        ProvenanceResult.new(**result_attributes(dependency, nil, nil, :unsupported, nil))
      end

      def error_result(dependency, artifact_sha256, error)
        ProvenanceResult.new(**result_attributes(dependency, nil, artifact_sha256, :error, nil, error))
      end

      # rubocop:disable Metrics/ParameterLists
      def result_attributes(dependency, provenance, artifact_sha256, status, github_release = nil, error = nil)
        {
          dependency:,
          status:,
          trusted_publishing: provenance&.trusted_publishing,
          repository: provenance&.repository,
          ref: provenance&.ref,
          workflow: provenance&.workflow,
          issuer: provenance&.issuer,
          subject: provenance&.subject,
          expected_sha256: provenance&.sha256,
          actual_sha256: artifact_sha256,
          error:,
          attestation_url: provenance&.attestation_url,
          github_release:
        }
      end

      # rubocop:enable Metrics/ParameterLists
      def provenance_status(provenance, artifact_sha256)
        return :unsupported unless provenance.trusted_publishing
        return :verified unless provenance.sha256 && artifact_sha256

        secure_compare(provenance.sha256, artifact_sha256) ? :verified : :mismatch
      end

      def github_release_result(provenance)
        @github_release_verifier.verify(provenance)
      rescue StandardError
        nil
      end

      def combine_status(provenance_status, github_release_status)
        return github_release_status if %i[mismatch error].include?(github_release_status)
        return provenance_status if github_release_status.nil? || github_release_status == :unsupported

        provenance_status == :unsupported ? github_release_status : provenance_status
      end

      def secure_compare(left, right)
        left = left.to_s
        right = right.to_s
        return false unless left.bytesize == right.bytesize

        left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
      end
    end
  end
end
