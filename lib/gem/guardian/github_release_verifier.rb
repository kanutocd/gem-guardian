# frozen_string_literal: true

module Gem
  module Guardian
    # Result object for GitHub release provenance checks.
    GitHubReleaseResult = Data.define(
      :dependency, :status, :repository, :tag, :checksum_assets, :signature_assets, :signed_tag,
      :signed_tag_reason, :release_attestation, :release_url, :error
    ) do
      # Returns true when the GitHub release checks succeeded.
      def verified?
        status == :verified
      end
    end

    # Verifies GitHub release checksum, signature, and attestation metadata.
    # rubocop:disable Metrics/ClassLength, Metrics/MethodLength, Metrics/ParameterLists, Metrics/CyclomaticComplexity
    class GitHubReleaseVerifier
      def initialize(client: GitHubClient.new)
        @client = client
      end

      # Verifies GitHub release metadata for +provenance+.
      def verify(provenance)
        repository = github_repository(provenance.repository)
        tag = github_tag(provenance)
        return unsupported_result(provenance, repository, tag) unless repository && tag

        release = @client.release(repository, tag)
        return unsupported_result(provenance, repository, tag) unless release

        checksum_assets = discovered_assets(release, checksum_asset_name?)
        signature_assets = discovered_assets(release, signature_asset_name?)
        tag_verification = @client.tag_verification(repository, tag)
        build_result(
          provenance,
          repository,
          tag,
          checksum_assets,
          signature_assets,
          tag_verification,
          release
        )
      rescue StandardError => e
        error_result(provenance, repository, tag, e)
      end

      private

      def build_result(provenance, repository, tag, checksum_assets, signature_assets, tag_verification, release)
        signed_tag = signed_tag?(tag_verification)
        attestation = release_attestation(release)
        status = release_status(signed_tag, attestation, tag_verification)
        GitHubReleaseResult.new(
          dependency: provenance.dependency,
          status: status,
          repository:,
          tag:,
          checksum_assets:,
          signature_assets:,
          signed_tag:,
          signed_tag_reason: verification_reason(tag_verification),
          release_attestation: attestation,
          release_url: release["html_url"],
          error: nil
        )
      end

      def unsupported_result(provenance, repository, tag)
        GitHubReleaseResult.new(
          dependency: provenance.dependency,
          status: :unsupported,
          repository: repository,
          tag: tag,
          checksum_assets: [],
          signature_assets: [],
          signed_tag: nil,
          signed_tag_reason: nil,
          release_attestation: nil,
          release_url: nil,
          error: nil
        )
      end

      def error_result(provenance, repository, tag, error)
        GitHubReleaseResult.new(
          dependency: provenance.dependency,
          status: :error,
          repository: repository,
          tag: tag,
          checksum_assets: [],
          signature_assets: [],
          signed_tag: nil,
          signed_tag_reason: nil,
          release_attestation: nil,
          release_url: nil,
          error: error
        )
      end

      def github_repository(repository)
        return if repository.nil?

        value = repository.to_s
        return unless value.match?(%r{\Ahttps://github\.com/[^/]+/[^/]+\z}) || value.match?(%r{\A[^/]+/[^/]+\z})

        value.delete_prefix("https://github.com/")
      end

      def github_tag(provenance)
        ref = provenance.ref.to_s
        return ref.delete_prefix("refs/tags/") if ref.start_with?("refs/tags/")

        subject = provenance.subject.to_s
        match = subject.match(%r{:ref:refs/tags/([^:]+)\z})
        match && match[1]
      end

      def discovered_assets(release, matcher)
        Array(release["assets"]).filter_map do |asset|
          name = asset.is_a?(Hash) ? asset["name"].to_s : asset.to_s
          name if matcher.call(name)
        end
      end

      def checksum_asset_name?
        @checksum_asset_name ||= lambda do |name|
          name.match?(/\.(?:sha256|sha256sum|checksum|checksums|sha)\z/i) ||
            name.match?(/\ASHA256SUMS(?:\.txt)?\z/i) ||
            name.match?(/\Achecksums(?:\.txt)?\z/i)
        end
      end

      def signature_asset_name?
        @signature_asset_name ||= lambda do |name|
          name.match?(/\.(?:sig|asc)\z/i) || name.match?(/\.(?:bundle|intoto\.jsonl)\z/i)
        end
      end

      def signed_tag?(verification)
        return nil unless verification.is_a?(Hash)

        verification["verified"] == true || verification["verified"].to_s.casecmp("true").zero?
      end

      def verification_reason(verification)
        return unless verification.is_a?(Hash)

        verification["reason"]
      end

      def release_attestation(release)
        value = release["attestations"] || release["attestation"] || release["provenance"] ||
                release["artifact_attestations"]
        return nil if value.nil?

        value.is_a?(TrueClass) || value.is_a?(FalseClass) ? value : true
      end

      def release_status(signed_tag, attestation, verification)
        return :verified if signed_tag == true && attestation == true
        return :mismatch if signed_tag == false
        return :mismatch if attestation == false
        return :error if verification.is_a?(Hash) &&
                         verification["verified"] == false &&
                         verification["reason"] == "invalid"

        :unsupported
      end
    end
    # rubocop:enable Metrics/ClassLength, Metrics/MethodLength, Metrics/ParameterLists, Metrics/CyclomaticComplexity
  end
end
