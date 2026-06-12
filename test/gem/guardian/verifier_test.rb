# frozen_string_literal: true

require_relative "../../test_helper"

module Gem
  module Guardian
    class VerifierTest < Minitest::Test
      FakeClient = Struct.new(:expected, keyword_init: true) do
        def expected_sha256(_dependency)
          expected
        end
      end

      FakeStore = Struct.new(:path, keyword_init: true) do
        def path_for(_dependency)
          path
        end
      end

      def test_verify_passes_when_checksums_match
        Dir.mktmpdir do |dir|
          path = File.join(dir, "sample.gem")
          File.binwrite(path, "hello")
          expected = Checksum.sha256_file(path)
          dep = Dependency.new(name: "sample", version: "1.0.0", platform: "ruby")

          result = Verifier.new(
            client: FakeClient.new(expected:),
            artifact_store: FakeStore.new(path:)
          ).verify(dep)

          assert result.ok?
          assert_equal expected, result.actual_sha256
        end
      end

      def test_verify_reports_mismatch
        Dir.mktmpdir do |dir|
          path = File.join(dir, "sample.gem")
          File.binwrite(path, "hello")
          dep = Dependency.new(name: "sample", version: "1.0.0", platform: "ruby")

          result = Verifier.new(
            client: FakeClient.new(expected: "0" * 64),
            artifact_store: FakeStore.new(path:)
          ).verify(dep)

          refute result.ok?
          assert_equal :mismatch, result.status
        end
      end
    end
  end
end
