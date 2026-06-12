# frozen_string_literal: true

require_relative "../../test_helper"

module Gem
  module Guardian
    class CLITest < Minitest::Test
      FakeLockfileData = Struct.new(:dependencies, :sha256_checksums, :missing_checksum_dependencies, keyword_init: true)
      FakeVerifierResult = Data.define(:dependency, :expected_sha256, :actual_sha256, :artifact_path, :status, :error, :checksum_source) do
        def ok?
          status == :ok
        end
      end

      class FakeVerifier
        attr_reader :expected_checksums

        def initialize(expected_checksums: {})
          @expected_checksums = expected_checksums
        end

        def verify_all(dependencies)
          dependencies.map do |dependency|
            FakeVerifierResult.new(
              dependency:,
              expected_sha256: expected_checksums[dependency] || "fallback",
              actual_sha256: "actual",
              artifact_path: "/tmp/#{dependency.name}.gem",
              status: :ok,
              error: nil,
              checksum_source: expected_checksums.key?(dependency) ? :lockfile : :rubygems
            )
          end
        end
      end

      class FakeLockfileParser
        def initialize(_path); end

        def parse
          dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
          FakeLockfileData.new(
            dependencies: [dependency],
            sha256_checksums: { dependency => "a" * 64 },
            missing_checksum_dependencies: []
          )
        end
      end

      def test_version
        stdout = StringIO.new
        status = CLI.new(["version"], stdout:).run

        assert_equal 0, status
        assert_equal "#{VERSION}\n", stdout.string
      end

      def test_unknown_command
        stderr = StringIO.new
        status = CLI.new(["wat"], stderr:).run

        assert_equal 2, status
        assert_match(/Unknown command/, stderr.string)
      end

      def test_verify_reports_lockfile_coverage
        stdout = StringIO.new
        status = CLI.new(
          ["verify"],
          stdout:,
          verifier_class: FakeVerifier,
          lockfile_parser_class: FakeLockfileParser
        ).run

        assert_equal 0, status
        assert_match(/PASS rake 13.2.1 ruby/, stdout.string)
        assert_match(/CHECKSUMS coverage: 1\/1/, stdout.string)
      end

      def test_verify_fails_when_lockfile_has_missing_checksums
        dependency = Dependency.new(name: "nokogiri", version: "1.18.9", platform: "x86_64-linux")
        parser_class = Class.new do
          define_method(:initialize) { |_path| }
          define_method(:parse) do
            FakeLockfileData.new(
              dependencies: [dependency],
              sha256_checksums: {},
              missing_checksum_dependencies: [dependency]
            )
          end
        end

        stdout = StringIO.new
        status = CLI.new(
          ["verify"],
          stdout:,
          verifier_class: FakeVerifier,
          lockfile_parser_class: parser_class
        ).run

        assert_equal 1, status
        assert_match(/MISSING nokogiri 1.18.9 x86_64-linux/, stdout.string)
        assert_match(/CHECKSUMS coverage: 0\/1/, stdout.string)
      end

      def test_verify_explicit_gems_do_not_use_fallback_label
        stdout = StringIO.new
        status = CLI.new(
          ["verify", "rake:13.2.1"],
          stdout:,
          verifier_class: FakeVerifier,
          lockfile_parser_class: FakeLockfileParser
        ).run

        assert_equal 0, status
        assert_match(/PASS rake 13.2.1 ruby/, stdout.string)
        refute_match(/FALLBACK/, stdout.string)
      end
    end
  end
end
