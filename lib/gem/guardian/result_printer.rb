# frozen_string_literal: true

module Gem
  module Guardian
    # Formats verification results for human-readable CLI output.
    # rubocop:disable Metrics/ClassLength
    class ResultPrinter
      # @param stdout [IO] output stream for formatted messages
      def initialize(stdout:)
        @stdout = stdout
      end

      # Prints a collection of verification results.
      def print_results(results, lockfile_mode:)
        results.each do |result|
          print_result(result, lockfile_mode:)
        end
      end

      # Prints one verification result.
      def print_result(result, lockfile_mode:)
        label = result_label(result)
        case result.status
        when :ok then print_ok_result(result, label, lockfile_mode)
        when :mismatch then print_mismatch_result(result, label)
        else print_error_result(result, label)
        end
      end

      # Prints a successful verification result.
      def print_ok_result(result, label, lockfile_mode)
        prefix = lockfile_mode && result.checksum_source == :rubygems ? "FALLBACK" : "PASS"
        @stdout.puts "#{prefix} #{label}"
        @stdout.puts "     sha256 #{result.actual_sha256}"
        @stdout.puts "     source #{result.checksum_source}" if lockfile_mode && result.checksum_source
      end

      # Prints a checksum mismatch.
      def print_mismatch_result(result, label)
        @stdout.puts "FAIL #{label}"
        @stdout.puts "     expected #{result.expected_sha256}"
        @stdout.puts "     actual   #{result.actual_sha256}"
      end

      # Prints an unexpected verifier error.
      def print_error_result(result, label)
        @stdout.puts "ERROR #{label}"
        @stdout.puts "      #{result.error.class}: #{result.error.message}"
      end

      # Prints lockfile checksum coverage.
      def print_lockfile_coverage(lockfile_data)
        covered = lockfile_data.dependencies.size - lockfile_data.missing_checksum_dependencies.size
        total = lockfile_data.dependencies.size
        @stdout.puts "CHECKSUMS coverage: #{covered}/#{total}"

        lockfile_data.missing_checksum_dependencies.each do |dependency|
          @stdout.puts "MISSING #{dependency.name} #{dependency.version} #{dependency.platform}"
        end
      end

      # Prints provenance verification results.
      def print_provenance_results(results)
        results.each do |result|
          print_provenance_result(result)
        end
      end

      # Prints one provenance verification result.
      def print_provenance_result(result)
        label = result_label(result)
        case result.status
        when :verified then print_verified_provenance_result(result, label)
        when :mismatch then print_mismatched_provenance_result(result, label)
        else print_unsupported_provenance_result(result, label)
        end
      end

      # Prints a successful provenance verification result.
      def print_verified_provenance_result(result, label)
        @stdout.puts "PROVENANCE PASS #{label}"
        @stdout.puts "           source trusted-publishing"
        provenance_fields(result).each do |label_name, value|
          @stdout.puts format_provenance_field(label_name, value) if value
        end
        print_github_release_result(result.github_release) if result.github_release
      end

      # Prints a provenance checksum mismatch.
      def print_mismatched_provenance_result(result, label)
        @stdout.puts "PROVENANCE FAIL #{label}"
        @stdout.puts "     expected #{result.expected_sha256}"
        @stdout.puts "     actual   #{result.actual_sha256}"
      end

      # Prints a provenance result when no trusted publishing data is available.
      def print_unsupported_provenance_result(_result, label)
        @stdout.puts "PROVENANCE UNSUPPORTED #{label}"
      end

      # Prints the CLI usage text.
      def usage
        @stdout.puts(USAGE)
      end

      # CLI usage text.
      USAGE = <<~USAGE.freeze
        gem-guardian #{VERSION}

        Usage:
          gem-guardian verify [--lockfile Gemfile.lock] [--json] [--provenance]
          gem-guardian verify GEM:VERSION[:PLATFORM] [GEM:VERSION[:PLATFORM] ...]
          gem-guardian version
          gem-guardian help

        Examples:
          gem-guardian verify
        gem-guardian verify sidekiq:8.1.6
        gem-guardian verify cdc-sidekiq:0.1.1
        gem-guardian verify nokogiri:1.18.9:x86_64-linux
        gem-guardian verify --json --provenance ratomic:0.4.1
      USAGE

      private

      def result_label(result)
        dependency = result.dependency
        "#{dependency.name} #{dependency.version} #{dependency.platform}"
      end

      # Returns the provenance fields to render for a verified result.
      def provenance_fields(result)
        [
          ["repository", result.repository],
          ["workflow", result.workflow],
          ["ref", result.ref],
          ["issuer", result.issuer],
          ["subject", result.subject],
          ["sha256", result.expected_sha256],
          ["attestation", result.attestation_url]
        ]
      end

      # Returns the GitHub release fields to render for a provenance result.
      # rubocop:disable Metrics/MethodLength
      def github_release_fields(result)
        [
          ["github release", result.status],
          ["release repo", result.repository],
          ["release tag", result.tag],
          ["checksum assets", result.checksum_assets.join(", ")],
          ["signature assets", result.signature_assets.join(", ")],
          ["signed tag", result.signed_tag],
          ["tag reason", result.signed_tag_reason],
          ["attestation", result.release_attestation],
          ["release url", result.release_url]
        ]
      end
      # rubocop:enable Metrics/MethodLength

      # Prints a GitHub release provenance result.
      def print_github_release_result(result)
        @stdout.puts "GITHUB RELEASE #{result.status.to_s.upcase}"
        github_release_fields(result).each do |label_name, value|
          @stdout.puts format_provenance_field(label_name, value) if value
        end
      end

      # Formats one provenance field line.
      def format_provenance_field(label, value)
        format("%<label>11s %<value>s", label:, value:)
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
