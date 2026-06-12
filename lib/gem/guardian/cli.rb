# frozen_string_literal: true

require "json"

# Namespace for gem-guardian CLI code.
module Gem
  # Command-line interface and output helpers.
  module Guardian
    # Command-line entry point for gem-guardian.
    # rubocop:disable Metrics/ClassLength, Metrics/ParameterLists
    class CLI
      # Starts the CLI with the provided argv.
      def self.start(argv)
        new(argv).run
      end

      def initialize(argv, stdout: $stdout, stderr: $stderr, verifier_class: Verifier,
                     lockfile_parser_class: LockfileParser, provenance_verifier_class: ProvenanceVerifier,
                     report_builder_class: ReportBuilder)
        @argv = argv.dup
        @stdout = stdout
        @stderr = stderr
        @verifier_class = verifier_class
        @lockfile_parser_class = lockfile_parser_class
        @provenance_verifier_class = provenance_verifier_class
        @report_builder_class = report_builder_class
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
      # rubocop:disable Metrics/MethodLength
      def verify
        json_output = flag?("--json")
        provenance_mode = flag?("--provenance")
        lockfile_data, dependencies, lockfile_path = resolve_dependencies
        return no_dependencies if dependencies.empty?

        results = verifier_for(lockfile_data).verify_all(dependencies)
        provenance_results = provenance_results_for(results, provenance_mode)
        output_verification(results, lockfile_data, provenance_results, json_output, lockfile_path)
        verification_exit_status(results, lockfile_data, provenance_results)
      rescue Error => e
        @stderr.puts e.message
        1
      end
      # rubocop:enable Metrics/MethodLength

      # Parses a GEM:VERSION[:PLATFORM] spec string.
      def parse_gem_spec(spec)
        name, version, platform = spec.split(":", 3)
        raise Error, "Expected GEM:VERSION[:PLATFORM], got: #{spec}" if name.to_s.empty? || version.to_s.empty?

        Dependency.new(name:, version:, platform: platform || "ruby")
      end

      def resolve_dependencies
        lockfile = option_value("--lockfile") || "Gemfile.lock"
        return [nil, @argv.map { |spec| parse_gem_spec(spec) }, nil] unless @argv.empty?

        lockfile_data = @lockfile_parser_class.new(lockfile).parse
        [lockfile_data, lockfile_data.dependencies, lockfile]
      end

      def verifier_for(lockfile_data)
        expected_checksums = lockfile_data&.sha256_checksums || {}
        @verifier_class.new(expected_checksums:)
      end

      def provenance_verifier_for
        @provenance_verifier_class.new
      end

      def provenance_results_for(results, provenance_mode)
        return [] unless provenance_mode

        provenance_verifier_for.verify_all(results)
      end

      def output_verification(results, lockfile_data, provenance_results, json_output, lockfile_path)
        if json_output
          write_json_report(results, lockfile_data, provenance_results, lockfile_path)
        else
          write_human_report(results, lockfile_data, provenance_results)
        end
      end

      def write_json_report(results, lockfile_data, provenance_results, lockfile_path)
        @stdout.puts JSON.pretty_generate(
          report_builder.build(results, lockfile_data:, provenance_results:, lockfile_path:)
        )
      end

      def write_human_report(results, lockfile_data, provenance_results)
        print_verification_report(results, lockfile_data)
        @result_printer.print_provenance_results(provenance_results) unless provenance_results.empty?
      end

      def print_verification_report(results, lockfile_data)
        lockfile_mode = !lockfile_data.nil?
        @result_printer.print_results(results, lockfile_mode:)
        return unless lockfile_data

        @result_printer.print_lockfile_coverage(lockfile_data)
      end

      def verification_exit_status(results, lockfile_data, provenance_results = [])
        all_ok = results.all?(&:ok?)
        all_covered = lockfile_data.nil? || lockfile_data.missing_checksum_dependencies.empty?
        provenance_ok = provenance_results.all? { |result| !%i[mismatch error].include?(result.status) }
        all_ok && all_covered && provenance_ok ? 0 : 1
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

      # Returns true when +name+ is present and removes it from argv.
      def flag?(name)
        index = @argv.index(name)
        return false unless index

        @argv.delete_at(index)
        true
      end

      # Returns the report builder for structured output.
      def report_builder
        @report_builder_class.new(version: VERSION)
      end

      # Prints usage text.
      def usage(_io = @stdout)
        @result_printer.usage
        0
      end
    end
    # rubocop:enable Metrics/ClassLength, Metrics/ParameterLists
  end
end
