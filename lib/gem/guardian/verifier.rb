# frozen_string_literal: true

module Gem
  module Guardian
    # Result object for a single verification attempt.
    VerificationResult = Data.define(:dependency, :expected_sha256, :actual_sha256, :artifact_path, :status, :error,
                                     :checksum_source) do
      # Returns true when the verification succeeded.
      def ok?
        status == :ok
      end
    end

    # Verifies gem artifacts against an expected checksum source.
    class Verifier
      def initialize(client: RubygemsClient.new, artifact_store: nil, expected_checksums: {})
        @client = client
        @artifact_store = artifact_store || ArtifactStore.new(client: @client)
        @expected_checksums = expected_checksums
      end

      # Verifies one dependency and returns a VerificationResult.
      def verify(dependency)
        expected, checksum_source = expected_sha256_for(dependency)
        build_verification_result(dependency, expected, checksum_source)
      rescue StandardError => e
        build_error_result(dependency, e)
      end

      # Verifies each dependency in +dependencies+.
      def verify_all(dependencies)
        dependencies.map { |dependency| verify(dependency) }
      end

      private

      def build_verification_result(dependency, expected, checksum_source)
        VerificationResult.new(**verification_attributes(dependency, expected, checksum_source))
      end

      def build_error_result(dependency, error)
        VerificationResult.new(
          dependency:,
          expected_sha256: nil,
          actual_sha256: nil,
          artifact_path: nil,
          status: :error,
          error:,
          checksum_source: nil
        )
      end

      def verification_attributes(dependency, expected, checksum_source)
        artifact_path = @artifact_store.path_for(dependency)
        actual = Checksum.sha256_file(artifact_path)
        { dependency:, expected_sha256: expected, actual_sha256: actual, artifact_path:,
          status: secure_compare(expected, actual) ? :ok : :mismatch, error: nil,
          checksum_source: }
      end

      # Constant-time comparison for checksum strings.
      def secure_compare(left, right)
        left = left.to_s
        right = right.to_s
        return false unless left.bytesize == right.bytesize

        left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
      end

      # Uses lockfile checksums first and falls back to RubyGems metadata.
      def expected_sha256_for(dependency)
        if @expected_checksums.key?(dependency)
          [@expected_checksums.fetch(dependency), :lockfile]
        else
          [@client.expected_sha256(dependency), :rubygems]
        end
      end
    end
  end
end
