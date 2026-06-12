# frozen_string_literal: true

module Gem
  module Guardian
    # Builds machine-readable verification reports.
    class ReportBuilder
      # @param version [String] gem-guardian version string
      def initialize(version:)
        @version = version
      end

      # Returns a JSON-friendly hash for the current verification run.
      def build(results, lockfile_data:, provenance_results: [], lockfile_path: nil)
        {
          version: @version,
          command: "verify",
          mode: lockfile_data ? "lockfile" : "explicit",
          lockfile: lockfile_path,
          checksums: checksum_summary(lockfile_data),
          results: results.map.with_index { |result, index| build_result(result, provenance_results[index]) }
        }
      end

      private

      def checksum_summary(lockfile_data)
        return nil unless lockfile_data

        {
          coverage: {
            covered: lockfile_data.dependencies.size - lockfile_data.missing_checksum_dependencies.size,
            total: lockfile_data.dependencies.size
          },
          missing: lockfile_data.missing_checksum_dependencies.map do |dependency|
            dependency_hash(dependency)
          end
        }
      end

      def build_result(result, provenance_result)
        dependency_hash(result.dependency).merge(
          checksum: checksum_hash(result)
        ).tap do |hash|
          hash[:provenance] = provenance_hash(provenance_result) if provenance_result
        end
      end

      def dependency_hash(dependency)
        {
          name: dependency.name,
          version: dependency.version,
          platform: dependency.platform
        }
      end

      def provenance_hash(result)
        provenance_fields(result).merge(
          error: error_hash(result.error)
        )
      end

      # Returns the non-error provenance fields.
      # rubocop:disable Metrics/MethodLength
      def provenance_fields(result)
        {
          status: result.status,
          trusted_publishing: result.trusted_publishing,
          repository: result.repository,
          ref: result.ref,
          workflow: result.workflow,
          issuer: result.issuer,
          subject: result.subject,
          expected_sha256: result.expected_sha256,
          actual_sha256: result.actual_sha256,
          attestation_url: result.attestation_url
        }
      end
      # rubocop:enable Metrics/MethodLength

      # Returns the checksum payload for a verification result.
      def checksum_hash(result)
        {
          status: result.status,
          expected_sha256: result.expected_sha256,
          actual_sha256: result.actual_sha256,
          artifact_path: result.artifact_path,
          checksum_source: result.checksum_source,
          error: error_hash(result.error)
        }
      end

      def error_hash(error)
        return nil unless error

        { class: error.class.name, message: error.message }
      end
    end
  end
end
