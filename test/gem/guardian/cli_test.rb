# frozen_string_literal: true

require "json"

require_relative "../../test_helper"

module Gem
  module Guardian
    class CLITest < Minitest::Test
      FakeLockfileData = Struct.new(:dependencies, :sha256_checksums, :missing_checksum_dependencies, :checksums,
                                    :checksums_section_present, keyword_init: true)
      FakeVerifierResult = Data.define(:dependency, :expected_sha256, :actual_sha256, :artifact_path, :status, :error,
                                       :checksum_source, :registry_sha256, :registry_checksum_provider, :registry_checksum_uri) do
        def ok?
          status == :ok
        end
      end

      FakeProvenanceResult = Data.define(
        :dependency, :status, :trusted_publishing, :repository, :ref, :workflow, :issuer, :subject,
        :expected_sha256, :actual_sha256, :error, :attestation_url, :github_release
      )
      FakeGitHubReleaseResult = Data.define(
        :dependency, :status, :repository, :tag, :checksum_assets, :signature_assets, :signed_tag,
        :signed_tag_reason, :release_attestation, :release_url, :error
      )

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
              checksum_source: expected_checksums.key?(dependency) ? :lockfile : :registry,
              registry_sha256: expected_checksums.key?(dependency) ? "registry" : nil,
              registry_checksum_provider: expected_checksums.key?(dependency) ? "test" : nil,
              registry_checksum_uri: expected_checksums.key?(dependency) ? "https://example.test/checksum" : nil
            )
          end
        end
      end

      class FakeProvenanceVerifier
        def initialize(_client = nil); end

        def verify_all(results)
          results.map do |result|
              FakeProvenanceResult.new(
                dependency: result.dependency,
                status: :verified,
              trusted_publishing: true,
              repository: "https://github.com/kanutocd/gem-guardian",
              ref: "refs/tags/v0.1.1",
              workflow: "release.yml",
              issuer: "https://token.actions.githubusercontent.com",
              subject: "repo:kanutocd/gem-guardian:ref:refs/tags/v0.1.1",
                expected_sha256: result.actual_sha256,
                actual_sha256: result.actual_sha256,
                error: nil,
                attestation_url: "https://rubygems.org",
                github_release: nil
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

      def test_help_and_no_args_show_usage
        stdout = StringIO.new
        help_status = CLI.new(["help"], stdout:).run
        nil_status = CLI.new([], stdout:).run

        assert_equal 0, help_status
        assert_equal 0, nil_status
        assert_match(/gem-guardian verify/, stdout.string)
      end

      def test_verify_uses_lockfile_option
        captured = []
        parser_class = Class.new do
          define_method(:initialize) do |path|
            captured << path
          end

          define_method(:parse) do
            dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
            FakeLockfileData.new(
              dependencies: [dependency],
              sha256_checksums: { dependency => "a" * 64 },
              missing_checksum_dependencies: []
            )
          end
        end

        stdout = StringIO.new
        status = CLI.new(
          ["verify", "--lockfile", "custom.lock"],
          stdout:,
          verifier_class: FakeVerifier,
          lockfile_parser_class: parser_class
        ).run

        assert_equal 0, status
        assert_equal ["custom.lock"], captured
      end


      def test_verify_can_filter_lockfile_dependencies_by_explicit_specs
        rake = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby", source: "https://rubygems.org/")
        sidekiq = Dependency.new(name: "sidekiq", version: "1.0.0", platform: "ruby", source: "https://rubygems.org/")
        parser_class = Class.new do
          define_method(:initialize) { |_path| }
          define_method(:parse) do
            FakeLockfileData.new(
              dependencies: [rake, sidekiq],
              sha256_checksums: { rake => "a" * 64, sidekiq => "b" * 64 },
              missing_checksum_dependencies: [],
              checksums: { rake => { "sha256" => "a" * 64 }, sidekiq => { "sha256" => "b" * 64 } },
              checksums_section_present: true
            )
          end
        end

        stdout = StringIO.new
        status = CLI.new(
          ["verify", "--lockfile", "Gemfile.lock", "sidekiq:1.0.0"],
          stdout:,
          verifier_class: FakeVerifier,
          lockfile_parser_class: parser_class
        ).run

        assert_equal 0, status
        assert_match(/PASS sidekiq 1.0.0 ruby/, stdout.string)
        refute_match(/PASS rake 13.2.1 ruby/, stdout.string)
        assert_match(%r{CHECKSUMS coverage: 1/1}, stdout.string)
      end

      def test_verify_can_filter_all_platforms_for_lockfile_dependency_when_platform_is_omitted
        linux = Dependency.new(name: "nokogiri", version: "1.19.3", platform: "x86_64-linux")
        darwin = Dependency.new(name: "nokogiri", version: "1.19.3", platform: "arm64-darwin")
        parser_class = Class.new do
          define_method(:initialize) { |_path| }
          define_method(:parse) do
            FakeLockfileData.new(
              dependencies: [linux, darwin],
              sha256_checksums: { linux => "a" * 64, darwin => "b" * 64 },
              missing_checksum_dependencies: [],
              checksums: { linux => { "sha256" => "a" * 64 }, darwin => { "sha256" => "b" * 64 } },
              checksums_section_present: true
            )
          end
        end

        stdout = StringIO.new
        status = CLI.new(
          ["verify", "--lockfile", "Gemfile.lock", "nokogiri:1.19.3"],
          stdout:,
          verifier_class: FakeVerifier,
          lockfile_parser_class: parser_class
        ).run

        assert_equal 0, status
        assert_match(/PASS nokogiri 1.19.3 x86_64-linux/, stdout.string)
        assert_match(/PASS nokogiri 1.19.3 arm64-darwin/, stdout.string)
        assert_match(%r{CHECKSUMS coverage: 2/2}, stdout.string)
      end

      def test_verify_reports_missing_explicit_lockfile_dependency
        parser_class = Class.new do
          define_method(:initialize) { |_path| }
          define_method(:parse) do
            FakeLockfileData.new(
              dependencies: [],
              sha256_checksums: {},
              missing_checksum_dependencies: [],
              checksums: {},
              checksums_section_present: true
            )
          end
        end

        stderr = StringIO.new
        status = CLI.new(
          ["verify", "--lockfile", "Gemfile.lock", "missing:1.0.0"],
          stderr:,
          verifier_class: FakeVerifier,
          lockfile_parser_class: parser_class
        ).run

        assert_equal 1, status
        assert_match(/Gem not found in lockfile: missing:1.0.0/, stderr.string)
      end

      def test_verify_rejects_missing_lockfile_value
        stderr = StringIO.new
        status = CLI.new(["verify", "--lockfile"], stderr:).run

        assert_equal 1, status
        assert_match(/requires a value/, stderr.string)
      end

      def test_verify_rejects_invalid_dependency_spec
        stderr = StringIO.new
        status = CLI.new(%w[verify rake], stderr:).run

        assert_equal 1, status
        assert_match(/Expected GEM:VERSION/, stderr.string)
      end

      def test_verify_returns_error_when_no_dependencies_are_found
        parser_class = Class.new do
          define_method(:initialize) { |_path| }
          define_method(:parse) do
            FakeLockfileData.new(
              dependencies: [],
              sha256_checksums: {},
              missing_checksum_dependencies: []
            )
          end
        end

        stderr = StringIO.new
        status = CLI.new(
          ["verify"],
          stdout: StringIO.new,
          stderr:,
          verifier_class: FakeVerifier,
          lockfile_parser_class: parser_class
        ).run

        assert_equal 1, status
        assert_match(/No gems found to verify/, stderr.string)
      end

      def test_verify_reports_lockfile_fallback
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
        assert_match(/FALLBACK nokogiri 1.18.9 x86_64-linux/, stdout.string)
        assert_match(%r{CHECKSUMS coverage: 0/1}, stdout.string)
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
        assert_match(%r{CHECKSUMS coverage: 1/1}, stdout.string)
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
        assert_match(%r{CHECKSUMS coverage: 0/1}, stdout.string)
      end

      def test_verify_reports_verifier_error_and_mismatch
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
        parser_class = Class.new do
          define_method(:initialize) { |_path| }
          define_method(:parse) do
            FakeLockfileData.new(
              dependencies: [dependency],
              sha256_checksums: { dependency => "a" * 64 },
              missing_checksum_dependencies: []
            )
          end
        end

        verifier_class = Class.new do
          define_method(:initialize) { |expected_checksums: {}| }
          define_method(:verify_all) do |dependencies|
            [
              FakeVerifierResult.new(
                dependency: dependencies.first,
                expected_sha256: "a" * 64,
                actual_sha256: "b" * 64,
                artifact_path: "/tmp/rake.gem",
                status: :mismatch,
                error: nil,
                checksum_source: :lockfile,
                registry_sha256: nil,
                registry_checksum_provider: nil,
                registry_checksum_uri: nil
              ),
              FakeVerifierResult.new(
                dependency: dependencies.first,
                expected_sha256: nil,
                actual_sha256: nil,
                artifact_path: nil,
                status: :error,
                error: IOError.new("boom"),
                checksum_source: nil,
                registry_sha256: nil,
                registry_checksum_provider: nil,
                registry_checksum_uri: nil
              )
            ]
          end
        end

        stdout = StringIO.new
        status = CLI.new(
          ["verify"],
          stdout:,
          verifier_class: verifier_class,
          lockfile_parser_class: parser_class
        ).run

        assert_equal 1, status
        assert_match(/FAIL rake 13.2.1 ruby/, stdout.string)
        assert_match(/ERROR rake 13.2.1 ruby/, stdout.string)
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

      def test_verify_can_emit_json_reports
        stdout = StringIO.new
        status = CLI.new(
          ["verify", "--json"],
          stdout:,
          verifier_class: FakeVerifier,
          lockfile_parser_class: FakeLockfileParser
        ).run

        report = JSON.parse(stdout.string)

        assert_equal 0, status
        assert_equal "verify", report["command"]
        assert_equal VERSION, report["version"]
        assert_equal "lockfile", report["mode"]
        assert_equal 1, report.dig("checksums", "coverage", "total")
        assert_equal "rake", report.dig("results", 0, "name")
        assert_equal "ok", report.dig("results", 0, "checksum", "status")
      end

      def test_verify_can_emit_json_for_explicit_specs
        stdout = StringIO.new
        status = CLI.new(
          ["verify", "--json", "rake:13.2.1"],
          stdout:,
          verifier_class: FakeVerifier,
          lockfile_parser_class: FakeLockfileParser
        ).run

        report = JSON.parse(stdout.string)

        assert_equal 0, status
        assert_equal "explicit", report["mode"]
        assert_nil report["checksums"]
        assert_equal "rake", report.dig("results", 0, "name")
      end

      def test_verify_can_emit_provenance_results
        stdout = StringIO.new
        status = CLI.new(
          ["verify", "--provenance"],
          stdout:,
          verifier_class: FakeVerifier,
          lockfile_parser_class: FakeLockfileParser,
          provenance_verifier_class: FakeProvenanceVerifier
        ).run

        assert_equal 0, status
        assert_match(/PROVENANCE PASS rake 13.2.1 ruby/, stdout.string)
        assert_match(/source trusted-publishing/, stdout.string)
      end

      def test_verify_can_emit_json_provenance_results
        stdout = StringIO.new
        status = CLI.new(
          ["verify", "--json", "--provenance"],
          stdout:,
          verifier_class: FakeVerifier,
          lockfile_parser_class: FakeLockfileParser,
          provenance_verifier_class: FakeProvenanceVerifier
        ).run

        report = JSON.parse(stdout.string)

        assert_equal 0, status
        assert_equal "verified", report.dig("results", 0, "provenance", "status")
        assert_equal true, report.dig("results", 0, "provenance", "trusted_publishing")
      end

      def test_verify_can_emit_github_release_results
        github_release = FakeGitHubReleaseResult.new(
          dependency: Dependency.new(name: "rake", version: "13.2.1", platform: "ruby"),
          status: :verified,
          repository: "kanutocd/gem-guardian",
          tag: "v0.1.1",
          checksum_assets: ["gem-guardian-0.1.1.gem.sha256"],
          signature_assets: ["gem-guardian-0.1.1.gem.sig"],
          signed_tag: true,
          signed_tag_reason: "valid",
          release_attestation: true,
          release_url: "https://github.com/kanutocd/gem-guardian/releases/tag/v0.1.1",
          error: nil
        )
        provenance_result = FakeProvenanceResult.new(
          dependency: github_release.dependency,
          status: :verified,
          trusted_publishing: true,
          repository: "https://github.com/kanutocd/gem-guardian",
          ref: "refs/tags/v0.1.1",
          workflow: "release.yml",
          issuer: "https://token.actions.githubusercontent.com",
          subject: "repo:kanutocd/gem-guardian:ref:refs/tags/v0.1.1",
          expected_sha256: "a" * 64,
          actual_sha256: "a" * 64,
          error: nil,
          attestation_url: "https://rubygems.org",
          github_release:
        )

        stdout = StringIO.new
        status = CLI.new(
          ["verify", "--provenance", "rake:13.2.1"],
          stdout:,
          verifier_class: Class.new do
            define_method(:initialize) { |expected_checksums:| }
            define_method(:verify_all) { |dependencies| dependencies.map { |_dependency| FakeVerifierResult.new(
              dependency: github_release.dependency,
              expected_sha256: "a" * 64,
              actual_sha256: "a" * 64,
              artifact_path: "/tmp/rake.gem",
              status: :ok,
              error: nil,
              checksum_source: :registry,
              registry_sha256: "a" * 64,
                registry_checksum_provider: "test",
                registry_checksum_uri: "https://example.test/checksum"
            ) } }
          end,
          provenance_verifier_class: Class.new do
            define_method(:initialize) { |_client = nil| }
            define_method(:verify_all) { |results| [provenance_result] }
          end,
          lockfile_parser_class: FakeLockfileParser
        ).run

        assert_equal 0, status
        assert_match(/GITHUB RELEASE VERIFIED/, stdout.string)
        assert_match(/checksum assets gem-guardian-0.1.1.gem.sha256/, stdout.string)
        assert_match(/signature assets gem-guardian-0.1.1.gem.sig/, stdout.string)
      end

      def test_verify_can_emit_json_github_release_results
        github_release = FakeGitHubReleaseResult.new(
          dependency: Dependency.new(name: "rake", version: "13.2.1", platform: "ruby"),
          status: :verified,
          repository: "kanutocd/gem-guardian",
          tag: "v0.1.1",
          checksum_assets: ["gem-guardian-0.1.1.gem.sha256"],
          signature_assets: ["gem-guardian-0.1.1.gem.sig"],
          signed_tag: true,
          signed_tag_reason: "valid",
          release_attestation: true,
          release_url: "https://github.com/kanutocd/gem-guardian/releases/tag/v0.1.1",
          error: nil
        )
        provenance_result = FakeProvenanceResult.new(
          dependency: github_release.dependency,
          status: :verified,
          trusted_publishing: true,
          repository: "https://github.com/kanutocd/gem-guardian",
          ref: "refs/tags/v0.1.1",
          workflow: "release.yml",
          issuer: "https://token.actions.githubusercontent.com",
          subject: "repo:kanutocd/gem-guardian:ref:refs/tags/v0.1.1",
          expected_sha256: "a" * 64,
          actual_sha256: "a" * 64,
          error: nil,
          attestation_url: "https://rubygems.org",
          github_release:
        )

        stdout = StringIO.new
        status = CLI.new(
          ["verify", "--json", "--provenance", "rake:13.2.1"],
          stdout:,
          verifier_class: Class.new do
            define_method(:initialize) { |expected_checksums:| }
            define_method(:verify_all) { |dependencies| dependencies.map { |_dependency| FakeVerifierResult.new(
              dependency: github_release.dependency,
              expected_sha256: "a" * 64,
              actual_sha256: "a" * 64,
              artifact_path: "/tmp/rake.gem",
              status: :ok,
              error: nil,
              checksum_source: :registry,
              registry_sha256: "a" * 64,
                registry_checksum_provider: "test",
                registry_checksum_uri: "https://example.test/checksum"
            ) } }
          end,
          provenance_verifier_class: Class.new do
            define_method(:initialize) { |_client = nil| }
            define_method(:verify_all) { |_results| [provenance_result] }
          end,
          lockfile_parser_class: FakeLockfileParser
        ).run

        report = JSON.parse(stdout.string)

        assert_equal 0, status
        assert_equal "verified", report.dig("results", 0, "provenance", "github_release", "status")
        assert_equal ["gem-guardian-0.1.1.gem.sig"], report.dig("results", 0, "provenance", "github_release", "signature_assets")
      end

      def test_verify_reports_mixed_provenance_statuses
        provenance_verifier_class = Class.new do
          define_method(:initialize) { |_client = nil| }

          define_method(:verify_all) do |results|
            [
              FakeProvenanceResult.new(
                dependency: results[0].dependency,
                status: :verified,
                trusted_publishing: true,
                repository: "https://github.com/kanutocd/gem-guardian",
                ref: "refs/tags/v0.1.1",
                workflow: nil,
                issuer: "https://token.actions.githubusercontent.com",
                subject: "repo:kanutocd/gem-guardian:ref:refs/tags/v0.1.1",
                expected_sha256: results[0].actual_sha256,
                actual_sha256: results[0].actual_sha256,
                error: nil,
                attestation_url: "https://rubygems.org",
                github_release: nil
              ),
              FakeProvenanceResult.new(
                dependency: results[1].dependency,
                status: :mismatch,
                trusted_publishing: true,
                repository: "https://github.com/kanutocd/gem-guardian",
                ref: "refs/tags/v0.1.1",
                workflow: "release.yml",
                issuer: "https://token.actions.githubusercontent.com",
                subject: "repo:kanutocd/gem-guardian:ref:refs/tags/v0.1.1",
                expected_sha256: "a" * 64,
                actual_sha256: "b" * 64,
                error: nil,
                attestation_url: "https://rubygems.org",
                github_release: nil
              ),
              FakeProvenanceResult.new(
                dependency: results[2].dependency,
                status: :unsupported,
                trusted_publishing: nil,
                repository: nil,
                ref: nil,
                workflow: nil,
                issuer: nil,
                subject: nil,
                expected_sha256: nil,
                actual_sha256: nil,
                error: nil,
                attestation_url: nil,
                github_release: nil
              )
            ]
          end
        end

        stdout = StringIO.new
        status = CLI.new(
          ["verify", "--provenance", "rake:13.2.1", "rake:13.2.1", "rake:13.2.1"],
          stdout:,
          verifier_class: FakeVerifier,
          provenance_verifier_class: provenance_verifier_class,
          lockfile_parser_class: FakeLockfileParser
        ).run

        assert_equal 1, status
        assert_match(/PROVENANCE PASS rake 13.2.1 ruby/, stdout.string)
        assert_match(/PROVENANCE FAIL rake 13.2.1 ruby/, stdout.string)
        assert_match(/PROVENANCE UNSUPPORTED rake 13.2.1 ruby/, stdout.string)
      end

      def test_verify_can_emit_json_provenance_errors
        provenance_verifier_class = Class.new do
          define_method(:initialize) { |_client = nil| }

          define_method(:verify_all) do |results|
            [
              FakeProvenanceResult.new(
                dependency: results.first.dependency,
                status: :error,
                trusted_publishing: true,
                repository: nil,
                ref: nil,
                workflow: nil,
                issuer: nil,
                subject: nil,
                expected_sha256: nil,
                actual_sha256: results.first.actual_sha256,
                error: RuntimeError.new("boom"),
                attestation_url: nil,
                github_release: nil
              )
            ]
          end
        end

        stdout = StringIO.new
        status = CLI.new(
          ["verify", "--json", "--provenance", "rake:13.2.1"],
          stdout:,
          verifier_class: FakeVerifier,
          provenance_verifier_class: provenance_verifier_class,
          lockfile_parser_class: FakeLockfileParser
        ).run

        report = JSON.parse(stdout.string)

        assert_equal 1, status
        assert_equal "error", report.dig("results", 0, "provenance", "status")
        assert_equal "RuntimeError", report.dig("results", 0, "provenance", "error", "class")
      end
    end
  end
end
