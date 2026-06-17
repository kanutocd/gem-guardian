# frozen_string_literal: true

require_relative "../../test_helper"

module Gem
  module Guardian
    class VerifierTest < Minitest::Test
      FakeClient = Struct.new(:expected, :error, keyword_init: true) do
        def expected_sha256(_dependency)
          raise error if error

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
          dep = Dependency.new(name: "sample", version: "1.0.0", platform: "ruby")
          expected = Checksum.sha256_file(path)

          result = Verifier.new(
            client: FakeClient.new(error: ChecksumNotFound.new("missing")),
            expected_checksums: { dep => expected },
            artifact_store: FakeStore.new(path:)
          ).verify(dep)

          assert result.ok?
          assert_equal expected, result.actual_sha256
          assert_equal :lockfile, result.checksum_source
          assert_nil result.registry_sha256
        end
      end

      def test_verify_cross_checks_registry_checksum_when_lockfile_checksum_exists
        Dir.mktmpdir do |dir|
          path = File.join(dir, "sample.gem")
          File.binwrite(path, "hello")
          dep = Dependency.new(name: "sample", version: "1.0.0", platform: "ruby")
          expected = Checksum.sha256_file(path)

          result = Verifier.new(
            client: FakeClient.new(expected:),
            expected_checksums: { dep => expected },
            artifact_store: FakeStore.new(path:)
          ).verify(dep)

          assert result.ok?
          assert_equal expected, result.expected_sha256
          assert_equal expected, result.registry_sha256
          assert_equal expected, result.actual_sha256
          assert_equal :lockfile, result.checksum_source
        end
      end

      def test_verify_fails_when_registry_checksum_disagrees_with_lockfile_and_artifact
        Dir.mktmpdir do |dir|
          path = File.join(dir, "sample.gem")
          File.binwrite(path, "hello")
          dep = Dependency.new(name: "sample", version: "1.0.0", platform: "ruby")
          expected = Checksum.sha256_file(path)

          result = Verifier.new(
            client: FakeClient.new(expected: "f" * 64),
            expected_checksums: { dep => expected },
            artifact_store: FakeStore.new(path:)
          ).verify(dep)

          refute result.ok?
          assert_equal :mismatch, result.status
          assert_equal expected, result.expected_sha256
          assert_equal "f" * 64, result.registry_sha256
          assert_equal expected, result.actual_sha256
          assert_equal :lockfile, result.checksum_source
        end
      end

      def test_verify_reports_mismatch
        Dir.mktmpdir do |dir|
          path = File.join(dir, "sample.gem")
          File.binwrite(path, "hello")
          dep = Dependency.new(name: "sample", version: "1.0.0", platform: "ruby")

          result = Verifier.new(
            client: FakeClient.new(error: ChecksumNotFound.new("missing")),
            expected_checksums: { dep => "0" * 64 },
            artifact_store: FakeStore.new(path:)
          ).verify(dep)

          refute result.ok?
          assert_equal :mismatch, result.status
          assert_equal :lockfile, result.checksum_source
        end
      end

      def test_verify_falls_back_to_rubygems_when_checksum_missing
        Dir.mktmpdir do |dir|
          path = File.join(dir, "sample.gem")
          File.binwrite(path, "hello")
          dep = Dependency.new(name: "sample", version: "1.0.0", platform: "ruby")
          expected = Checksum.sha256_file(path)

          result = Verifier.new(
            client: FakeClient.new(expected:),
            artifact_store: FakeStore.new(path:),
            expected_checksums: {}
          ).verify(dep)

          assert result.ok?
          assert_equal :registry, result.checksum_source
          assert_equal expected, result.registry_sha256
        end
      end


      def test_verify_records_artifact_checksum_when_expected_checksum_is_unavailable
        Dir.mktmpdir do |dir|
          path = File.join(dir, "private.gem")
          File.binwrite(path, "private")
          dep = Dependency.new(name: "private", version: "1.0.0", platform: "ruby")
          actual = Checksum.sha256_file(path)

          result = Verifier.new(
            client: FakeClient.new(error: ChecksumNotFound.new("missing")),
            artifact_store: FakeStore.new(path:),
            expected_checksums: {}
          ).verify(dep)

          assert result.ok?
          assert_equal :artifact, result.checksum_source
          assert_nil result.expected_sha256
          assert_equal actual, result.actual_sha256
        end
      end

      def test_verify_returns_error_when_artifact_store_fails
        dep = Dependency.new(name: "sample", version: "1.0.0", platform: "ruby")

        result = Verifier.new(
          client: FakeClient.new(expected: "a" * 64),
          artifact_store: Class.new do
            def path_for(_dependency)
              raise IOError, "cache unavailable"
            end
          end.new,
          expected_checksums: { dep => "a" * 64 }
        ).verify(dep)

        assert_equal :error, result.status
        assert_instance_of IOError, result.error
      end

      def test_secure_compare_rejects_different_lengths
        verifier = Verifier.new(client: FakeClient.new(expected: "a" * 64),
                                artifact_store: FakeStore.new(path: "/tmp/unused"))

        refute verifier.send(:secure_compare, "abc", "abcd")
      end

      RegistryClient = Struct.new(:registry_result, :legacy_expected, :resolved_dependency, keyword_init: true) do
        def registry_checksum(_dependency)
          registry_result
        end

        def expected_sha256(_dependency)
          raise ChecksumNotFound, "missing" unless legacy_expected

          legacy_expected
        end

        def resolve_dependency(dependency)
          resolved_dependency || dependency
        end
      end

      def test_explicit_mode_uses_registry_checksum_provider_result
        Dir.mktmpdir do |dir|
          path = File.join(dir, "sample.gem")
          File.binwrite(path, "provider")
          dep = Dependency.new(name: "sample", version: "1.0.0", platform: "ruby")
          expected = Checksum.sha256_file(path)
          provider_result = ChecksumProvider::Result.new(
            sha256: expected,
            source: :registry,
            provider: "test-registry",
            verification_uri: "https://registry.example/checksums/sample"
          )

          result = Verifier.new(
            client: RegistryClient.new(registry_result: provider_result),
            artifact_store: FakeStore.new(path:),
            expected_checksums: {}
          ).verify(dep)

          assert result.ok?
          assert_equal :registry, result.checksum_source
          assert_equal expected, result.expected_sha256
          assert_equal expected, result.registry_sha256
          assert_equal "test-registry", result.registry_checksum_provider
          assert_equal "https://registry.example/checksums/sample", result.registry_checksum_uri
        end
      end

      def test_lockfile_mode_falls_back_to_legacy_registry_checksum_when_provider_returns_nil
        Dir.mktmpdir do |dir|
          path = File.join(dir, "sample.gem")
          File.binwrite(path, "legacy")
          dep = Dependency.new(name: "sample", version: "1.0.0", platform: "ruby")
          expected = Checksum.sha256_file(path)

          result = Verifier.new(
            client: RegistryClient.new(registry_result: nil, legacy_expected: expected),
            artifact_store: FakeStore.new(path:),
            expected_checksums: { dep => expected }
          ).verify(dep)

          assert result.ok?
          assert_equal :lockfile, result.checksum_source
          assert_equal expected, result.registry_sha256
          assert_equal "legacy", result.registry_checksum_provider
        end
      end

      def test_resolve_dependency_uses_client_when_available
        Dir.mktmpdir do |dir|
          path = File.join(dir, "sample.gem")
          File.binwrite(path, "resolved")
          dep = Dependency.new(name: "sample", version: "1.0.0", platform: "ruby")
          resolved = Dependency.new(name: "sample", version: "1.0.0", platform: "ruby", source: "https://example.test")
          expected = Checksum.sha256_file(path)

          result = Verifier.new(
            client: RegistryClient.new(resolved_dependency: resolved, registry_result: nil, legacy_expected: expected),
            artifact_store: FakeStore.new(path:),
            expected_checksums: { dep => expected }
          ).verify(dep)

          assert result.ok?
          assert_equal resolved, result.dependency
        end
      end

    end
  end
end
