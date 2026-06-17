# frozen_string_literal: true

module Gem
  module Guardian
    # Result object for a single verification attempt.
    #
    # @!attribute [r] dependency
    #   @return [Dependency] dependency being verified
    # @!attribute [r] expected_sha256
    #   @return [String, nil] independent checksum used as the primary expected digest,
    #     or +nil+ when the artifact was only recorded
    # @!attribute [r] actual_sha256
    #   @return [String, nil] SHA256 computed from the downloaded `.gem` artifact
    # @!attribute [r] artifact_path
    #   @return [String, nil] local path to the downloaded artifact
    # @!attribute [r] status
    #   @return [Symbol] +:ok+, +:mismatch+, or +:error+
    # @!attribute [r] error
    #   @return [Exception, nil] verification error when +status+ is +:error+
    # @!attribute [r] checksum_source
    #   @return [Symbol, nil] +:lockfile+, +:registry+, or +:artifact+
    # @!attribute [r] registry_sha256
    #   @return [String, nil] registry or publisher checksum used as an optional cross-check
    # @!attribute [r] registry_checksum_provider
    #   @return [String, nil] checksum provider name, such as +rubygems-api+, +compact-index+, or +url+
    # @!attribute [r] registry_checksum_uri
    #   @return [String, nil] sanitized URI where the registry or publisher checksum can be inspected
    VerificationResult = Data.define(:dependency, :expected_sha256, :actual_sha256, :artifact_path, :status, :error,
                                     :checksum_source, :registry_sha256, :registry_checksum_provider,
                                     :registry_checksum_uri) do
      # Indicates whether the verification result is successful.
      #
      # For +:artifact+ results, success means the artifact digest was recorded,
      # not that an independent checksum comparison occurred.
      #
      # @return [Boolean] +true+ when +status+ is +:ok+
      def ok?
        status == :ok
      end
    end

    # Verifies gem artifacts against lockfile, registry, or artifact checksum sources.
    #
    # Verification follows the trust-source priority documented in the README:
    # lockfile checksums are preferred, registry or publisher checksums are used
    # for ad-hoc verification when available, and artifact-only digests are
    # recorded when no independent checksum exists.
    class Verifier
      def initialize(client: RubygemsClient.new, artifact_store: nil, expected_checksums: {})
        @client = client
        @artifact_store = artifact_store || ArtifactStore.new(client: @client)
        @expected_checksums = expected_checksums
      end

      # Verifies one dependency.
      #
      # @param dependency [Dependency] dependency to resolve, download, hash, and verify
      # @return [VerificationResult] verification result for the dependency
      def verify(dependency)
        resolved_dependency = resolve_dependency(dependency)
        expected, checksum_source = expected_sha256_for(dependency, resolved_dependency)
        build_verification_result(resolved_dependency, expected, checksum_source)
      rescue StandardError => e
        build_error_result(dependency, e)
      end

      # Verifies each dependency in +dependencies+.
      #
      # @param dependencies [Enumerable<Dependency>] dependencies to verify
      # @return [Array<VerificationResult>] verification results in dependency order
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
          checksum_source: nil,
          registry_sha256: nil,
          registry_checksum_provider: nil,
          registry_checksum_uri: nil
        )
      end

      def verification_attributes(dependency, expected, checksum_source)
        artifact_path = @artifact_store.path_for(dependency)
        actual = Checksum.sha256_file(artifact_path)
        registry_checksum = registry_checksum_for(dependency, checksum_source, expected)
        checksum_source = :artifact if checksum_source == :registry && registry_checksum.nil?
        registry_sha256 = registry_checksum&.sha256
        expected = registry_sha256 if checksum_source == :registry

        { dependency:, expected_sha256: expected, actual_sha256: actual, artifact_path:,
          status: checksum_status(expected, actual, registry_sha256, checksum_source), error: nil,
          checksum_source:, registry_sha256:,
          registry_checksum_provider: registry_checksum&.provider,
          registry_checksum_uri: registry_checksum&.verification_uri }
      end

      # Constant-time comparison for checksum strings.
      #
      # @param left [String, nil] first checksum value
      # @param right [String, nil] second checksum value
      # @return [Boolean] +true+ when both checksum strings are byte-identical
      def secure_compare(left, right)
        left = left.to_s
        right = right.to_s
        return false unless left.bytesize == right.bytesize

        left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
      end

      # Selects the primary expected checksum source.
      #
      # @param dependency [Dependency] original dependency requested by the caller
      # @param _resolved_dependency [Dependency] dependency after registry source resolution
      # @return [(String, Symbol)] expected checksum and source label
      def expected_sha256_for(dependency, _resolved_dependency)
        if @expected_checksums.key?(dependency)
          [@expected_checksums.fetch(dependency), :lockfile]
        else
          [nil, :registry]
        end
      rescue ChecksumNotFound
        [nil, :artifact]
      end

      # Returns the registry or publisher checksum when available.
      #
      # @param dependency [Dependency] dependency being verified
      # @param checksum_source [Symbol] primary checksum source selected for the result
      # @param _expected [String, nil] primary expected checksum, usually from the lockfile
      # @return [ChecksumProvider::Result, nil] independent registry/publisher checksum metadata when available
      #
      # Lockfile verification can be stronger when the registry also exposes a
      # checksum. In that case gem-guardian verifies the three-way relationship:
      #
      #   lockfile SHA256 == registry SHA256 == artifact SHA256
      #
      # Registries are not required to expose checksum metadata. Missing registry
      # metadata does not weaken the lockfile comparison; it only means the
      # optional registry cross-check cannot be performed.
      def registry_checksum_for(dependency, checksum_source, _expected = nil)
        if checksum_source == :registry
          return @client.registry_checksum(dependency) if @client.respond_to?(:registry_checksum)

          sha = @client.expected_sha256(dependency)
          return ChecksumProvider::Result.new(sha256: sha, source: :registry, provider: "legacy", verification_uri: nil)
        end
        return nil if checksum_source == :artifact

        checksum = @client.registry_checksum(dependency) if @client.respond_to?(:registry_checksum)
        return checksum if checksum

        sha = @client.expected_sha256(dependency)
        ChecksumProvider::Result.new(sha256: sha, source: :registry, provider: "legacy", verification_uri: nil)
      rescue ChecksumNotFound
        nil
      end

      def checksum_status(expected, actual, registry_sha256, checksum_source)
        return :ok if checksum_source == :artifact
        return :mismatch unless expected && secure_compare(expected, actual)
        return :mismatch if registry_sha256 && !secure_compare(registry_sha256, actual)

        :ok
      end

      def resolve_dependency(dependency)
        return dependency unless @client.respond_to?(:resolve_dependency)

        @client.resolve_dependency(dependency)
      end
    end
  end
end
