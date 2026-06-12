# frozen_string_literal: true

module Gem
  module Guardian
    class LockfileParser
      GEM_LINE = /^ {4}([A-Za-z0-9_.-]+) \(([^)]+)\)/

      def initialize(path = "Gemfile.lock")
        @path = path
      end

      def dependencies
        raise LockfileError, "Lockfile not found: #{@path}" unless File.file?(@path)

        specs_section = false
        File.readlines(@path, chomp: true).filter_map do |line|
          specs_section = true if line == "  specs:"
          specs_section = false if specs_section && line.match?(/^[A-Z]/)
          next unless specs_section

          match = GEM_LINE.match(line)
          next unless match

          name = match[1]
          version_and_platform = match[2]
          version, platform = split_version_and_platform(version_and_platform)
          Dependency.new(name:, version:, platform:)
        end
      end

      private

      # Bundler renders native platforms as `1.2.3-x86_64-linux` in the spec line.
      # Ruby versions remain plain, for example `1.2.3`.
      def split_version_and_platform(value)
        version, platform = value.split("-", 2)
        [version, platform || "ruby"]
      end
    end
  end
end
