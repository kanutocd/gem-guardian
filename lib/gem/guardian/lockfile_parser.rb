# frozen_string_literal: true

module Gem
  module Guardian
    class LockfileParser
      GEM_LINE = /^ {4}([A-Za-z0-9_.-]+) \(([^)]+)\)/
      CHECKSUM_LINE = /^ {2}([A-Za-z0-9_.-]+) \(([^)]+)\) (.+)$/
      LockfileData = Data.define(:dependencies, :checksums, :checksums_section_present) do
        def checksum_for(dependency, algorithm = "sha256")
          checksums.fetch(dependency, {}).fetch(algorithm, nil)
        end

        def sha256_checksums
          checksums.each_with_object({}) do |(dependency, algorithms), memo|
            digest = algorithms["sha256"]
            memo[dependency] = digest if digest
          end
        end

        def missing_checksum_dependencies
          dependencies.reject { |dependency| sha256_checksums.key?(dependency) }
        end

        def checksums_present?
          checksums_section_present
        end
      end

      def initialize(path = "Gemfile.lock")
        @path = path
      end

      def parse
        raise LockfileError, "Lockfile not found: #{@path}" unless File.file?(@path)

        dependencies = []
        checksums = {}
        section = nil

        File.readlines(@path, chomp: true).each do |line|
          case line
          when "  specs:"
            section = :specs
            next
          when "CHECKSUMS"
            section = :checksums
            next
          when /^[A-Z]/
            section = nil
            next
          end

          case section
          when :specs
            match = GEM_LINE.match(line)
            next unless match

            name = match[1]
            version_and_platform = match[2]
            version, platform = split_version_and_platform(version_and_platform)
            dependencies << Dependency.new(name:, version:, platform:)
          when :checksums
            match = CHECKSUM_LINE.match(line)
            next unless match

            name = match[1]
            version_and_platform = match[2]
            checksum_blob = match[3]
            version, platform = split_version_and_platform(version_and_platform)
            dependency = Dependency.new(name:, version:, platform:)
            checksums[dependency] ||= {}
            checksum_blob.split(",").each do |pair|
              algorithm, digest = pair.split("=", 2).map(&:strip)
              next if algorithm.to_s.empty? || digest.to_s.empty?

              checksums[dependency][algorithm] = digest
            end
          end
        end

        LockfileData.new(dependencies, checksums, checksums.any?)
      end

      def dependencies
        parse.dependencies
      end

      def checksums
        parse.checksums
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
