# frozen_string_literal: true

module Gem
  module Guardian
    class CLI
      def self.start(argv)
        new(argv).run
      end

      def initialize(argv, stdout: $stdout, stderr: $stderr)
        @argv = argv.dup
        @stdout = stdout
        @stderr = stderr
      end

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

      def verify
        lockfile = option_value("--lockfile") || "Gemfile.lock"
        gems = @argv
        dependencies = if gems.empty?
                         LockfileParser.new(lockfile).dependencies
                       else
                         gems.map { |spec| parse_gem_spec(spec) }
                       end

        if dependencies.empty?
          @stderr.puts "No gems found to verify."
          return 1
        end

        results = Verifier.new.verify_all(dependencies)
        print_results(results)
        results.all?(&:ok?) ? 0 : 1
      rescue Error => e
        @stderr.puts e.message
        1
      end

      def parse_gem_spec(spec)
        name, version, platform = spec.split(":", 3)
        raise Error, "Expected GEM:VERSION[:PLATFORM], got: #{spec}" if name.to_s.empty? || version.to_s.empty?

        Dependency.new(name:, version:, platform: platform || "ruby")
      end

      def option_value(name)
        index = @argv.index(name)
        return unless index

        value = @argv[index + 1]
        raise Error, "#{name} requires a value" unless value

        @argv.slice!(index, 2)
        value
      end

      def print_results(results)
        results.each do |result|
          dependency = result.dependency
          label = "#{dependency.name} #{dependency.version} #{dependency.platform}"
          case result.status
          when :ok
            @stdout.puts "PASS #{label}"
            @stdout.puts "     sha256 #{result.actual_sha256}"
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
  end
end
