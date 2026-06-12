# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Gem
  module Guardian
    # Reads GitHub release and tag metadata for provenance checks.
    class GitHubClient
      # Default GitHub API endpoint used by the client.
      DEFAULT_HOST = "https://api.github.com"

      def initialize(host: DEFAULT_HOST, http: Net::HTTP)
        @host = host.delete_suffix("/")
        @http = http
      end

      # Returns the release payload for +repository+ and +tag+.
      def release(repository, tag)
        fetch_json("/repos/#{repository}/releases/tags/#{tag}")
      rescue StandardError
        nil
      end

      # Returns the tag verification payload for +repository+ and +tag+.
      # rubocop:disable Metrics/CyclomaticComplexity
      def tag_verification(repository, tag)
        ref = fetch_json("/repos/#{repository}/git/ref/tags/#{tag}")
        return unless ref.is_a?(Hash)

        object = ref["object"]
        return unless object.is_a?(Hash)
        return object["verification"] if object["type"] == "tag" && object["verification"].is_a?(Hash)

        commit = fetch_json("/repos/#{repository}/commits/#{object["sha"]}")
        commit.is_a?(Hash) ? commit["commit"]&.fetch("verification", nil) : nil
      rescue StandardError
        nil
      end
      # rubocop:enable Metrics/CyclomaticComplexity

      private

      def fetch_json(path)
        JSON.parse(get(path))
      end

      def get(path)
        uri = URI("#{@host}#{path}")
        response = @http.get_response(uri)
        return response.body if response.is_a?(Net::HTTPSuccess)

        raise Error, "GET #{uri} failed with #{response.code} #{response.message}"
      end
    end
  end
end
