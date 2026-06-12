# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Gem
  module Guardian
    class RubygemsClient
      DEFAULT_HOST = "https://rubygems.org"

      def initialize(host: DEFAULT_HOST, http: Net::HTTP)
        @host = host.delete_suffix("/")
        @http = http
      end

      def expected_sha256(dependency)
        versions = JSON.parse(get("/api/v1/versions/#{dependency.name}.json"))
        version = versions.find do |item|
          item["number"] == dependency.version && platform_matches?(item["platform"], dependency.platform)
        end

        sha = version && (version["sha"] || version["sha256"] || version["checksum"])
        raise ChecksumNotFound, "No SHA256 found for #{dependency.name} #{dependency.version} #{dependency.platform}" if blank?(sha)

        sha.downcase
      end

      def download_gem(dependency, destination)
        body = get("/downloads/#{dependency.gem_filename}")
        File.binwrite(destination, body)
        destination
      rescue StandardError => e
        raise ArtifactFetchError, "Could not fetch #{dependency.gem_filename}: #{e.message}"
      end

      private

      def get(path)
        uri = URI("#{@host}#{path}")
        response = @http.get_response(uri)
        return response.body if response.is_a?(Net::HTTPSuccess)

        raise Error, "GET #{uri} failed with #{response.code} #{response.message}"
      end

      def platform_matches?(remote_platform, wanted_platform)
        normalized_remote = remote_platform.to_s.empty? ? "ruby" : remote_platform.to_s
        normalized_wanted = wanted_platform.to_s.empty? ? "ruby" : wanted_platform.to_s
        normalized_remote == normalized_wanted
      end

      def blank?(value)
        value.nil? || value.to_s.empty?
      end
    end
  end
end
