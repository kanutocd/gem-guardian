# frozen_string_literal: true

require "yaml"
require "gem/guardian/checksum_provider"
require "gem/guardian/error"

module Gem
  module Guardian
    # Project-level configuration loaded from `.gem-guardian.yml`.
    #
    # The configuration file is intentionally small and policy-oriented. Its
    # first supported use case is declaring publisher checksum providers for
    # private gem registries that do not expose RubyGems.org checksum metadata.
    #
    # @example Publisher checksum provider
    #   checksum_providers:
    #     - name: contribsys-sidekiq
    #       source: https://gems.contribsys.com/
    #       template: https://gems.contribsys.com/checksums/{filename}.sha256
    class Configuration
      DEFAULT_PATH = ".gem-guardian.yml"

      attr_reader :path, :checksum_providers

      # Loads configuration from `.gem-guardian.yml` in the current directory,
      # or from `GEM_GUARDIAN_CONFIG` when that environment variable is set.
      #
      # @param path [String, nil] explicit configuration path
      # @param cwd [String] working directory used for relative paths
      # @return [Configuration] parsed configuration. Missing files produce an empty configuration.
      # @raise [Error] when the YAML is invalid or has an unsupported shape
      def self.load(path: ENV.fetch("GEM_GUARDIAN_CONFIG", DEFAULT_PATH), cwd: Dir.pwd)
        full_path = absolute_path(path, cwd)
        return new(path: full_path) unless File.file?(full_path)

        data = YAML.safe_load_file(full_path, permitted_classes: [], aliases: false) || {}
        raise Error, "#{full_path} must contain a YAML mapping" unless data.is_a?(Hash)

        new(path: full_path, checksum_providers: build_checksum_providers(data.fetch("checksum_providers", [])))
      rescue Psych::Exception => e
        raise Error, "Invalid gem-guardian config #{full_path}: #{e.message}"
      end

      # @param path [String, nil] source path of the loaded configuration
      # @param checksum_providers [Array<#checksum_for>] configured checksum providers
      def initialize(path: nil, checksum_providers: [])
        @path = path
        @checksum_providers = checksum_providers
      end

      # @return [Boolean] whether the config declares any checksum providers
      def checksum_providers?
        !checksum_providers.empty?
      end

      class << self
        private

        def absolute_path(path, cwd)
          path = DEFAULT_PATH if path.to_s.empty?
          File.absolute_path(path, cwd)
        end

        def build_checksum_providers(entries)
          raise Error, "checksum_providers must be an array" unless entries.is_a?(Array)

          entries.map { |entry| build_checksum_provider(entry) }
        end

        def build_checksum_provider(entry)
          raise Error, "checksum provider entries must be mappings" unless entry.is_a?(Hash)

          template = entry["template"]
          raise Error, "checksum provider template is required" if template.to_s.empty?

          provider = ChecksumProvider::Url.new(
            template: template,
            provider_name: entry.fetch("name", "url")
          )
          source = entry["source"]
          return provider if source.to_s.empty?

          ChecksumProvider::SourceScoped.new(source:, provider:)
        end
      end
    end
  end
end
