# frozen_string_literal: true

require "net/http"
require "uri"

module Gem
  module Guardian
    # Pluggable checksum providers for registry or publisher supplied SHA256 data.
    #
    # A provider answers one question:
    #
    #   "Is there an independent SHA256 for this dependency, and where did it come from?"
    #
    # Providers are intentionally separate from artifact hashing. The downloaded
    # `.gem` file is always hashed locally by {Verifier}; provider results are
    # independent trust anchors that can be compared with that artifact digest.
    module ChecksumProvider
      # Independent checksum data returned by a provider.
      #
      # @!attribute [r] sha256
      #   @return [String] lowercase SHA256 hex digest
      # @!attribute [r] source
      #   @return [Symbol] provider source category, such as +:registry+ or +:publisher+
      # @!attribute [r] provider
      #   @return [String] provider implementation name
      # @!attribute [r] verification_uri
      #   @return [String, nil] URI a user or tool can inspect to verify the checksum source
      Result = Data.define(:sha256, :source, :provider, :verification_uri) do
        # @return [Hash{Symbol => Object}] JSON-friendly representation of the provider result,
        #   including the checksum, provider name, source category, and verification URI
        def to_h
          {
            sha256: sha256,
            source: source,
            provider: provider,
            verification_uri: verification_uri
          }
        end
      end

      # Reads checksum metadata from the RubyGems.org-style versions API.
      class RubyGemsApi
        # @param dependency [Dependency] dependency whose checksum should be looked up
        # @param client [RubygemsClient] client used to query the RubyGems.org-style API
        # @return [Result, nil] provider result when checksum metadata is available, otherwise +nil+
        def checksum_for(dependency, client:)
          client.rubygems_api_checksum(dependency)
        end
      end

      # Reads checksum metadata from a RubyGems/Bundler compact index endpoint.
      class CompactIndex
        # @param dependency [Dependency] dependency whose checksum should be looked up
        # @param client [RubygemsClient] client used to query the compact index endpoint
        # @return [Result, nil] provider result when compact index checksum metadata is available, otherwise +nil+
        def checksum_for(dependency, client:)
          client.compact_index_registry_checksum(dependency)
        end
      end

      # Restricts another checksum provider to dependencies resolved from a
      # matching gem source.
      #
      # This lets project configuration attach publisher checksum URLs to a
      # private registry without probing that URL for every public gem. Source
      # matching is prefix-based after trailing slashes are normalized, so a
      # configured source such as `https://gems.contribsys.com/` matches locked
      # dependency sources under that registry.
      class SourceScoped
        # @param source [String] source URI prefix this provider applies to
        # @param provider [#checksum_for] checksum provider to delegate to
        def initialize(source:, provider:)
          @source = normalize_source(source)
          @provider = provider
        end

        # @param dependency [Dependency] dependency whose source should be checked
        # @param client [RubygemsClient] client passed to the delegated provider
        # @return [Result, nil] delegated checksum result when the source matches, otherwise +nil+
        def checksum_for(dependency, client:)
          return unless source_matches?(dependency.source)

          @provider.checksum_for(dependency, client:)
        end

        private

        def source_matches?(source)
          return false if source.to_s.empty?

          normalize_source(source).start_with?(@source)
        end

        def normalize_source(source)
          value = source.to_s
          uri = URI(value)
          uri.user = nil
          uri.password = nil
          uri.to_s.delete_suffix("/")
        rescue URI::InvalidURIError
          value.delete_suffix("/")
        end
      end

      # Reads checksum metadata from a publisher-controlled checksum URL.
      #
      # This is intentionally generic. Commercial or self-hosted publishers can
      # expose a stable checksum file without implementing RubyGems.org metadata
      # APIs. For example, a publisher could host:
      #
      #   https://example.com/checksums/mammoth-pro-1.0.0.gem.sha256
      #
      # The template supports these placeholders:
      #
      # - +{name}+
      # - +{version}+
      # - +{platform}+
      # - +{filename}+
      #
      # The response body may contain either a bare SHA256 or a line such as:
      #
      #   <sha256>  <filename>
      class Url
        SHA256_PATTERN = /\b([a-fA-F0-9]{64})\b/
        OPEN_TIMEOUT = 10
        READ_TIMEOUT = 30

        # @param template [String] URL template containing dependency placeholders such as +{filename}+
        # @param http [#get_response] HTTP client, mainly for tests. When omitted, +Net::HTTP+ is used with explicit timeouts.
        # @param provider_name [String] provider label used in reports and JSON output
        def initialize(template:, http: Net::HTTP, provider_name: "url")
          @template = template
          @http = http
          @provider_name = provider_name
        end

        # @param dependency [Dependency] dependency whose checksum should be looked up
        # @param client [RubygemsClient] client used to sanitize the verification URI
        # @return [Result, nil] provider result when the configured URL returns a parseable SHA256, otherwise +nil+
        def checksum_for(dependency, client:)
          uri = URI(expand_template(dependency))
          response = http_get(uri)
          return unless response.is_a?(Net::HTTPSuccess)

          sha256 = response.body.to_s[SHA256_PATTERN, 1]
          return unless sha256

          Result.new(
            sha256: sha256.downcase,
            source: :publisher,
            provider: @provider_name,
            verification_uri: client.sanitize_uri(uri)
          )
        rescue StandardError
          nil
        end

        private

        def expand_template(dependency)
          filename = dependency.gem_filename
          @template
            .gsub("{name}", dependency.name)
            .gsub("{version}", dependency.version)
            .gsub("{platform}", dependency.platform)
            .gsub("{filename}", filename)
        end

        def http_get(uri)
          return @http.get_response(uri) unless @http == Net::HTTP

          Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                              open_timeout: OPEN_TIMEOUT,
                                              read_timeout: READ_TIMEOUT) do |http|
            http.request(Net::HTTP::Get.new(uri.request_uri))
          end
        end
      end
    end
  end
end
