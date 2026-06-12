# frozen_string_literal: true

module Gem
  module Guardian
    # Formats verification results for human-readable CLI output.
    class ResultPrinter
      def initialize(stdout:)
        @stdout = stdout
      end

      def print_results(results, lockfile_mode:)
        results.each do |result|
          print_result(result, lockfile_mode:)
        end
      end

      def print_result(result, lockfile_mode:)
        label = result_label(result)
        case result.status
        when :ok then print_ok_result(result, label, lockfile_mode)
        when :mismatch then print_mismatch_result(result, label)
        else print_error_result(result, label)
        end
      end

      def print_ok_result(result, label, lockfile_mode)
        prefix = lockfile_mode && result.checksum_source == :rubygems ? "FALLBACK" : "PASS"
        @stdout.puts "#{prefix} #{label}"
        @stdout.puts "     sha256 #{result.actual_sha256}"
        @stdout.puts "     source #{result.checksum_source}" if lockfile_mode && result.checksum_source
      end

      def print_mismatch_result(result, label)
        @stdout.puts "FAIL #{label}"
        @stdout.puts "     expected #{result.expected_sha256}"
        @stdout.puts "     actual   #{result.actual_sha256}"
      end

      def print_error_result(result, label)
        @stdout.puts "ERROR #{label}"
        @stdout.puts "      #{result.error.class}: #{result.error.message}"
      end

      def print_lockfile_coverage(lockfile_data)
        covered = lockfile_data.dependencies.size - lockfile_data.missing_checksum_dependencies.size
        total = lockfile_data.dependencies.size
        @stdout.puts "CHECKSUMS coverage: #{covered}/#{total}"

        lockfile_data.missing_checksum_dependencies.each do |dependency|
          @stdout.puts "MISSING #{dependency.name} #{dependency.version} #{dependency.platform}"
        end
      end

      def usage
        @stdout.puts(USAGE)
      end

      USAGE = <<~USAGE.freeze
        gem-guardian #{VERSION}

        Usage:
          gem-guardian verify [--lockfile Gemfile.lock]
          gem-guardian verify GEM:VERSION[:PLATFORM] [GEM:VERSION[:PLATFORM] ...]
          gem-guardian version

        Examples:
          gem-guardian verify
        gem-guardian verify sidekiq:8.0.8
        gem-guardian verify nokogiri:1.18.9:x86_64-linux
      USAGE

      private

      def result_label(result)
        dependency = result.dependency
        "#{dependency.name} #{dependency.version} #{dependency.platform}"
      end
    end
  end
end
