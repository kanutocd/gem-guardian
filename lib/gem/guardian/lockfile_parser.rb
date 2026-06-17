# frozen_string_literal: true

module Gem
  module Guardian
    # Parses Gemfile.lock and exposes dependencies and checksum data.
    class LockfileParser
      # Matches dependency lines in the specs section.
      GEM_LINE = /^ {4}([A-Za-z0-9_.-]+) \(([^)]+)\)/
      # Matches Bundler remote lines inside GEM sections.
      REMOTE_LINE = /^  remote: (.+)$/
      # Matches checksum lines in the CHECKSUMS section.
      CHECKSUM_LINE = /^ {2}([A-Za-z0-9_.-]+) \(([^)]+)\) (.+)$/
      # Parsed lockfile data for the verify command.
      LockfileData = Data.define(:dependencies, :checksums, :checksums_section_present) do
        # Returns the checksum for +dependency+ and +algorithm+, if present.
        def checksum_for(dependency, algorithm = "sha256")
          checksums.fetch(dependency, {}).fetch(algorithm, nil)
        end

        # Returns a dependency => sha256 checksum map.
        def sha256_checksums
          checksums.each_with_object({}) do |(dependency, algorithms), memo|
            digest = algorithms["sha256"]
            memo[dependency] = digest if digest
          end
        end

        # Returns dependencies that do not have a sha256 checksum.
        def missing_checksum_dependencies
          dependencies.reject { |dependency| sha256_checksums.key?(dependency) }
        end

        # Returns true if the lockfile contained a CHECKSUMS section.
        def checksums_present?
          checksums_section_present
        end
      end

      def initialize(path = "Gemfile.lock")
        @path = path
      end

      # Parses the lockfile into dependencies and checksum metadata.
      def parse
        raise LockfileError, "Lockfile not found: #{@path}" unless File.file?(@path)

        dependencies = []
        checksums = {}
        section = nil
        source = nil

        File.readlines(@path, chomp: true).each do |line|
          section = section_for(line, section)
          source = source_for(line, section, source)
          parse_specs_line(line, dependencies, source) if section == :specs
          parse_checksums_line(line, checksums, dependencies) if section == :checksums
        end

        LockfileData.new(dependencies, checksums, checksums.any?)
      end

      # Returns the dependencies listed in the lockfile.
      def dependencies
        parse.dependencies
      end

      # Returns the raw checksum map extracted from the lockfile.
      def checksums
        parse.checksums
      end

      private

      def section_for(line, current_section)
        case line
        when "GEM"
          :gem
        when "  specs:"
          :specs
        when "CHECKSUMS"
          :checksums
        when /^[A-Z]/
          nil
        else
          current_section
        end
      end

      def source_for(line, section, current_source)
        return nil unless %i[gem specs].include?(section)

        match = REMOTE_LINE.match(line)
        return normalize_source(match[1]) if match
        return nil if section == :gem

        current_source
      end

      def normalize_source(source)
        source.to_s.delete_suffix("/") == RubygemsClient::DEFAULT_HOST ? nil : source
      end

      def parse_specs_line(line, dependencies, source)
        match = GEM_LINE.match(line)
        return unless match

        name = match[1]
        version_and_platform = match[2]
        version, platform = split_version_and_platform(version_and_platform)
        dependencies << Dependency.new(name:, version:, platform:, source:)
      end

      def parse_checksums_line(line, checksums, dependencies)
        match = CHECKSUM_LINE.match(line)
        return unless match

        name = match[1]
        version_and_platform = match[2]
        checksum_blob = match[3]
        version, platform = split_version_and_platform(version_and_platform)
        dependency = dependency_for_checksum(dependencies, name, version, platform)
        checksums[dependency] ||= {}
        register_checksum_pairs(checksums[dependency], checksum_blob)
      end

      def dependency_for_checksum(dependencies, name, version, platform)
        dependencies.find do |dependency|
          dependency.name == name && dependency.version == version && dependency.platform == platform
        end || Dependency.new(name:, version:, platform:)
      end

      def register_checksum_pairs(checksum_store, checksum_blob)
        checksum_blob.split(",").each do |pair|
          algorithm, digest = pair.split("=", 2).map(&:strip)
          next if algorithm.to_s.empty? || digest.to_s.empty?

          checksum_store[algorithm] = digest
        end
      end

      # Bundler renders native platforms as `1.2.3-x86_64-linux` in the spec line.
      # Ruby versions remain plain, for example `1.2.3`.
      def split_version_and_platform(value)
        version, platform = value.split("-", 2)
        [version, platform || "ruby"]
      end
    end
  end
end
