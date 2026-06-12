# frozen_string_literal: true

module Gem
  module Guardian
    VerificationResult = Data.define(:dependency, :expected_sha256, :actual_sha256, :artifact_path, :status, :error) do
      def ok?
        status == :ok
      end
    end

    class Verifier
      def initialize(client: RubygemsClient.new, artifact_store: nil)
        @client = client
        @artifact_store = artifact_store || ArtifactStore.new(client: @client)
      end

      def verify(dependency)
        expected = @client.expected_sha256(dependency)
        artifact_path = @artifact_store.path_for(dependency)
        actual = Checksum.sha256_file(artifact_path)
        status = secure_compare(expected, actual) ? :ok : :mismatch

        VerificationResult.new(
          dependency:,
          expected_sha256: expected,
          actual_sha256: actual,
          artifact_path:,
          status:,
          error: nil
        )
      rescue StandardError => e
        VerificationResult.new(
          dependency:,
          expected_sha256: nil,
          actual_sha256: nil,
          artifact_path: nil,
          status: :error,
          error: e
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
    end
  end
end
