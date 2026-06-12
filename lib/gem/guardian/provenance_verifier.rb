# frozen_string_literal: true

module Gem
  module Guardian
    # Result object for a provenance verification attempt.
    ProvenanceResult = Data.define(
      :dependency, :status, :trusted_publishing, :repository, :ref, :workflow, :issuer, :subject,
      :expected_sha256, :actual_sha256, :error, :attestation_url
    ) do
      # Returns true when provenance verification succeeded.
      def verified?
        status == :verified
      end
    end

    # Verifies RubyGems Trusted Publishing provenance metadata.
    class ProvenanceVerifier
      def initialize(client: RubygemsClient.new)
        @client = client
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

      # rubocop:disable Metrics/MethodLength
      def build_result(dependency, provenance, artifact_sha256)
        ProvenanceResult.new(**result_attributes(
          dependency, provenance, artifact_sha256, provenance_status(provenance, artifact_sha256)
        ))
      end

      def unsupported_result(dependency)
        ProvenanceResult.new(**result_attributes(dependency, nil, nil, :unsupported))
      end

      def error_result(dependency, artifact_sha256, error)
        ProvenanceResult.new(**result_attributes(dependency, nil, artifact_sha256, :error, error))
      end

      def result_attributes(dependency, provenance, artifact_sha256, status, error = nil)
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
          attestation_url: provenance&.attestation_url
        }
      end
      # rubocop:enable Metrics/MethodLength

      def provenance_status(provenance, artifact_sha256)
        return :unsupported unless provenance.trusted_publishing
        return :verified unless provenance.sha256 && artifact_sha256

        secure_compare(provenance.sha256, artifact_sha256) ? :verified : :mismatch
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
