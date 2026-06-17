# frozen_string_literal: true

module Gem
  module Guardian
    # Audits provenance support across gems visible from configured registry sources.
    #
    # The audit intentionally verifies provenance metadata only. It does not download
    # every artifact by default because a full checksum audit of a registry can be
    # expensive and unfriendly to remote services. Project-level checksum verification
    # remains the responsibility of `gem-guardian verify` and Bundler lockfiles.
    class RegistryAudit
      # One audited registry entry.
      EntryResult = Data.define(:entry, :provenance) do
        # Returns the dependency represented by this entry.
        def dependency
          entry.dependency
        end
      end

      # Summary of a registry provenance audit.
      Result = Data.define(:results) do
        # Count by provenance status.
        def counts
          results.each_with_object(Hash.new(0)) do |result, memo|
            memo[result.provenance.status] += 1
          end
        end

        # Entries with verified provenance.
        def verified
          by_status(:verified)
        end

        # Entries without Trusted Publishing provenance support.
        def unsupported
          by_status(:unsupported)
        end

        # Entries that errored while checking provenance.
        def errors
          by_status(:error)
        end

        # Entries whose provenance checksum mismatched the artifact checksum.
        def mismatches
          by_status(:mismatch)
        end

        # Total audited entries.
        def total
          results.size
        end

        private

        def by_status(status)
          results.select { |result| result.provenance.status == status }
        end
      end

      # @param registry [Registry] registry enumerator
      # @param provenance_verifier [ProvenanceVerifier] provenance checker
      def initialize(registry: Registry.new, provenance_verifier: ProvenanceVerifier.new)
        @registry = registry
        @provenance_verifier = provenance_verifier
      end

      # Runs the audit.
      #
      # @param limit [Integer, nil] maximum number of latest entries to inspect
      # @return [Result] aggregate audit result containing per-gem provenance outcomes
      def run(limit: nil)
        Result.new(
          @registry.each_latest_spec(limit:).map do |entry|
            EntryResult.new(entry:, provenance: @provenance_verifier.verify(entry.dependency))
          end
        )
      end
    end
  end
end
