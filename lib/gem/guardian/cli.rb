# frozen_string_literal: true

require "json"

# Namespace for gem-guardian CLI code.
module Gem
  # Command-line interface and output helpers.
  module Guardian
    # Command-line entry point for gem-guardian.
    # rubocop:disable Metrics/ClassLength
    class CLI
      # Lightweight lockfile data adapter used when a user verifies only a subset
      # of gems from a Bundler lockfile.
      #
      # {LockfileParser} returns the full dependency graph and all parsed checksum
      # entries. When the CLI receives both +--lockfile+ and explicit
      # +GEM:VERSION[:PLATFORM]+ arguments, this view narrows that data to the
      # requested dependencies while preserving the same reader methods consumed by
      # {Verifier}, {ReportBuilder}, and {ResultPrinter}.
      #
      # @!attribute [r] dependencies
      #   @return [Array<Dependency>] dependencies selected for verification
      # @!attribute [r] checksums
      #   @return [Hash{Dependency => Hash{String => String}}] checksum algorithms
      #     keyed by dependency
      # @!attribute [r] checksums_section_present
      #   @return [Boolean] whether the source lockfile contained a +CHECKSUMS+
      #     section
      LockfileDataView = Data.define(:dependencies, :checksums, :checksums_section_present) do
        # Looks up a checksum for a dependency and algorithm.
        #
        # @param dependency [Dependency] dependency to look up
        # @param algorithm [String] checksum algorithm name, currently usually
        #   +"sha256"+
        # @return [String, nil] checksum digest when present, otherwise +nil+
        def checksum_for(dependency, algorithm = "sha256")
          checksums.fetch(dependency, {}).fetch(algorithm, nil)
        end

        # Returns only SHA256 checksums from the filtered lockfile data.
        #
        # @return [Hash{Dependency => String}] selected dependencies mapped to
        #   their SHA256 digest
        def sha256_checksums
          checksums.each_with_object({}) do |(dependency, algorithms), memo|
            digest = algorithms["sha256"]
            memo[dependency] = digest if digest
          end
        end

        # Lists selected dependencies that do not have SHA256 lockfile coverage.
        #
        # @return [Array<Dependency>] dependencies missing a SHA256 checksum in
        #   the lockfile view
        def missing_checksum_dependencies
          dependencies.reject { |dependency| sha256_checksums.key?(dependency) }
        end

        # Indicates whether the original lockfile contained a +CHECKSUMS+
        # section.
        #
        # @return [Boolean] +true+ when the source lockfile had checksum metadata
        def checksums_present?
          checksums_section_present
        end
      end

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

      # Parses a GEM:VERSION[:PLATFORM] spec string.
      def parse_gem_spec(spec, default_platform: "ruby")
        name, version, platform = spec.split(":", 3)
        raise Error, "Expected GEM:VERSION[:PLATFORM], got: #{spec}" if name.to_s.empty? || version.to_s.empty?

        Dependency.new(name:, version:, platform: platform || default_platform)
      end

      def resolve_dependencies
        lockfile_path = option_value("--lockfile")
        return resolve_explicit_dependencies unless lockfile_path

        lockfile_data = @lockfile_parser_class.new(lockfile_path).parse
        return [lockfile_data, lockfile_data.dependencies, lockfile_path] if @argv.empty?

        filtered_data = filter_lockfile_data(lockfile_data, @argv.map { |spec| parse_gem_spec(spec, default_platform: nil) })
        [filtered_data, filtered_data.dependencies, lockfile_path]
      end

      def resolve_explicit_dependencies
        return [nil, @argv.map { |spec| parse_gem_spec(spec) }, nil] unless @argv.empty?

        lockfile = "Gemfile.lock"
        lockfile_data = @lockfile_parser_class.new(lockfile).parse
        [lockfile_data, lockfile_data.dependencies, lockfile]
      end

      def filter_lockfile_data(lockfile_data, requested_dependencies)
        dependencies = requested_dependencies.flat_map do |requested|
          matches = matching_lockfile_dependencies(lockfile_data.dependencies, requested)
          raise Error, "Gem not found in lockfile: #{requested.name}:#{requested.version}" if matches.empty?

          matches
        end.uniq
        checksums = lockfile_data.checksums.select { |dependency, _algorithms| dependencies.include?(dependency) }
        LockfileDataView.new(dependencies, checksums, lockfile_data.checksums_section_present)
      end

      def matching_lockfile_dependencies(lockfile_dependencies, requested)
        lockfile_dependencies.select do |dependency|
          dependency.name == requested.name &&
            dependency.version == requested.version &&
            (requested.platform.nil? || dependency.platform == requested.platform)
        end
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
    # rubocop:enable Metrics/ClassLength
  end
end
