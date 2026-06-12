# frozen_string_literal: true

# Namespace for gem-guardian CLI code.
module Gem
  # Command-line interface and output helpers.
  module Guardian
    # Command-line entry point for gem-guardian.
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
        @result_printer = ResultPrinter.new(stdout:)
      end

      # Dispatches the requested subcommand and returns an exit status.
      def run
        dispatch(@argv.shift)
      end

      private

      def dispatch(command)
        case command
        when "verify" then verify
        when "version", "--version", "-v" then print_version
        when "help", "--help", "-h", nil then usage
        else
          unknown_command(command)
        end
      end

      # Runs the verify subcommand.
      def verify
        lockfile_data, dependencies = resolve_dependencies
        return no_dependencies if dependencies.empty?

        results = verifier_for(lockfile_data).verify_all(dependencies)
        print_verification_report(results, lockfile_data)
        verification_exit_status(results, lockfile_data)
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

      def resolve_dependencies
        lockfile = option_value("--lockfile") || "Gemfile.lock"
        return [nil, @argv.map { |spec| parse_gem_spec(spec) }] unless @argv.empty?

        lockfile_data = @lockfile_parser_class.new(lockfile).parse
        [lockfile_data, lockfile_data.dependencies]
      end

      def verifier_for(lockfile_data)
        expected_checksums = lockfile_data&.sha256_checksums || {}
        @verifier_class.new(expected_checksums:)
      end

      def print_verification_report(results, lockfile_data)
        lockfile_mode = !lockfile_data.nil?
        @result_printer.print_results(results, lockfile_mode:)
        return unless lockfile_data

        @result_printer.print_lockfile_coverage(lockfile_data)
      end

      def verification_exit_status(results, lockfile_data)
        all_ok = results.all?(&:ok?)
        all_covered = lockfile_data.nil? || lockfile_data.missing_checksum_dependencies.empty?
        all_ok && all_covered ? 0 : 1
      end

      def no_dependencies
        @stderr.puts "No gems found to verify."
        1
      end

      def print_version
        @stdout.puts VERSION
        0
      end

      def unknown_command(command)
        @stderr.puts "Unknown command: #{command}"
        usage(@stderr)
        2
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

      # Prints usage text.
      def usage(_io = @stdout)
        @result_printer.usage
        0
      end
    end
  end
end
