# frozen_string_literal: true

# Namespace for gem-guardian CLI code.
module Gem
  # Command-line interface and output helpers.
  module Guardian
    # Command-line entry point for gem-guardian.
    # rubocop:disable Metrics/ClassLength
    class CLI
      # Starts the CLI with the provided argv.
      def self.start(argv)
        new(argv).run
      end

      def initialize(argv, stdout: $stdout, stderr: $stderr, verifier_class: Verifier,
                     lockfile_parser_class: LockfileParser)
        @argv = argv.dup
        @stdout = stdout
        @stderr = stderr
        @verifier_class = verifier_class
        @lockfile_parser_class = lockfile_parser_class
      end

      # Dispatches the requested subcommand and returns an exit status.
      def run
        command = @argv.shift
        case command
        when "verify"
          verify
        when "version", "--version", "-v"
          @stdout.puts VERSION
          0
        when "help", "--help", "-h", nil
          usage
          0
        else
          @stderr.puts "Unknown command: #{command}"
          usage(@stderr)
          2
        end
      end

      private

      # Runs the verify subcommand.
      def verify
        lockfile = option_value("--lockfile") || "Gemfile.lock"
        gems = @argv
        lockfile_data = nil
        dependencies = if gems.empty?
                         lockfile_data = @lockfile_parser_class.new(lockfile).parse
                         lockfile_data.dependencies
                       else
                         gems.map { |spec| parse_gem_spec(spec) }
                       end

        if dependencies.empty?
          @stderr.puts "No gems found to verify."
          return 1
        end

        results = @verifier_class.new(expected_checksums: lockfile_data&.sha256_checksums || {}).verify_all(dependencies)
        print_results(results, lockfile_mode: !lockfile_data.nil?)
        print_lockfile_coverage(lockfile_data) if lockfile_data

        all_ok = results.all?(&:ok?)
        all_covered = lockfile_data.nil? || lockfile_data.missing_checksum_dependencies.empty?
        all_ok && all_covered ? 0 : 1
      rescue Error => e
        @stderr.puts e.message
        1
      end

      # Parses a GEM:VERSION[:PLATFORM] spec string.
      def parse_gem_spec(spec)
        name, version, platform = spec.split(":", 3)
        raise Error, "Expected GEM:VERSION[:PLATFORM], got: #{spec}" if name.to_s.empty? || version.to_s.empty?

        Dependency.new(name:, version:, platform: platform || "ruby")
      end

      # Returns and removes an option value from argv.
      def option_value(name)
        index = @argv.index(name)
        return unless index

        value = @argv[index + 1]
        raise Error, "#{name} requires a value" unless value

        @argv.slice!(index, 2)
        value
      end

      # Prints verification results in a concise human-readable format.
      def print_results(results, lockfile_mode:)
        results.each do |result|
          dependency = result.dependency
          label = "#{dependency.name} #{dependency.version} #{dependency.platform}"
          case result.status
          when :ok
            prefix = lockfile_mode && result.checksum_source == :rubygems ? "FALLBACK" : "PASS"
            @stdout.puts "#{prefix} #{label}"
            @stdout.puts "     sha256 #{result.actual_sha256}"
            @stdout.puts "     source #{result.checksum_source}" if lockfile_mode && result.checksum_source
          when :mismatch
            @stdout.puts "FAIL #{label}"
            @stdout.puts "     expected #{result.expected_sha256}"
            @stdout.puts "     actual   #{result.actual_sha256}"
          else
            @stdout.puts "ERROR #{label}"
            @stdout.puts "      #{result.error.class}: #{result.error.message}"
          end
        end
      end

      # Prints lockfile checksum coverage information.
      def print_lockfile_coverage(lockfile_data)
        covered = lockfile_data.dependencies.size - lockfile_data.missing_checksum_dependencies.size
        total = lockfile_data.dependencies.size
        @stdout.puts "CHECKSUMS coverage: #{covered}/#{total}"

        lockfile_data.missing_checksum_dependencies.each do |dependency|
          @stdout.puts "MISSING #{dependency.name} #{dependency.version} #{dependency.platform}"
        end
      end

      # Prints usage text.
      def usage(io = @stdout)
        io.puts <<~USAGE
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
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
