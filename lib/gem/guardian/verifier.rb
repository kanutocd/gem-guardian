# frozen_string_literal: true

module Gem
  module Guardian
    VerificationResult = Data.define(:dependency, :expected_sha256, :actual_sha256, :artifact_path, :status, :error, :checksum_source) do
      def ok?
        status == :ok
      end
    end

    class Verifier
      def initialize(client: RubygemsClient.new, artifact_store: nil, expected_checksums: {})
        @client = client
        @artifact_store = artifact_store || ArtifactStore.new(client: @client)
        @expected_checksums = expected_checksums
      end

      def verify(dependency)
        expected, checksum_source = expected_sha256_for(dependency)
        artifact_path = @artifact_store.path_for(dependency)
        actual = Checksum.sha256_file(artifact_path)
        status = secure_compare(expected, actual) ? :ok : :mismatch

        VerificationResult.new(
          dependency:,
          expected_sha256: expected,
          actual_sha256: actual,
          artifact_path:,
          status:,
          error: nil,
          checksum_source:
        )
      rescue StandardError => e
        VerificationResult.new(
          dependency:,
          expected_sha256: nil,
          actual_sha256: nil,
          artifact_path: nil,
          status: :error,
          error: e,
          checksum_source: nil
        )
      end

      def verify_all(dependencies)
        dependencies.map { |dependency| verify(dependency) }
      end

      private

      def secure_compare(left, right)
        left = left.to_s
        right = right.to_s
        return false unless left.bytesize == right.bytesize

        left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
      end

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
