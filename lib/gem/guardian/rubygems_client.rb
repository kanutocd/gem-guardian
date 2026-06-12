# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Gem
  module Guardian
    # Reads checksum metadata from RubyGems.org and downloads gem artifacts.
    class RubygemsClient
      # Trusted Publishing provenance metadata extracted from RubyGems version data.
      TrustedPublishingProvenance = Data.define(
        :trusted_publishing, :repository, :ref, :workflow, :issuer, :subject, :sha256, :attestation_url
      )

      # Default RubyGems.org endpoint used by the client.
      DEFAULT_HOST = "https://rubygems.org"

      def initialize(host: DEFAULT_HOST, http: Net::HTTP)
        @host = host.delete_suffix("/")
        @http = http
      end

      # Returns the expected SHA256 checksum for +dependency+.
      def expected_sha256(dependency)
        version = matching_version(dependency)
        sha = version && version_checksum(version)
        if blank?(sha)
          raise ChecksumNotFound,
                "No SHA256 found for #{dependency.name} #{dependency.version} #{dependency.platform}"
        end

        sha.downcase
      end

      # Returns trusted publishing provenance data for +dependency+ when RubyGems exposes it.
      def trusted_publishing_provenance(dependency)
        version = matching_version(dependency)
        version && provenance_for(version)
      end

      # Downloads the .gem file for +dependency+ into +destination+.
      def download_gem(dependency, destination)
        body = get("/downloads/#{dependency.gem_filename}")
        File.binwrite(destination, body)
        destination
      rescue StandardError => e
        raise ArtifactFetchError, "Could not fetch #{dependency.gem_filename}: #{e.message}"
      end

      private

      def matching_version(dependency)
        versions = JSON.parse(get("/api/v1/versions/#{dependency.name}.json"))
        versions.find do |item|
          item["number"] == dependency.version && platform_matches?(item["platform"], dependency.platform)
        end
      end

      def version_checksum(version)
        version["sha"] || version["sha256"] || version["checksum"]
      end

      # Extracts trusted publishing provenance data from a RubyGems version payload.
      def provenance_for(version)
        provenance = provenance_payload(version)
        trusted_publishing = trusted_publishing?(provenance, version)
        return unless trusted_publishing || provenance.any?

        TrustedPublishingProvenance.new(**provenance_attributes(provenance).merge(trusted_publishing:))
      end

      # Returns the provenance payload from a version hash.
      def provenance_payload(version)
        payload = version["provenance"] || version["trusted_publishing"] || version["attestation"] || {}
        payload.is_a?(Hash) ? payload : {}
      end

      # Returns the first non-empty provenance string value for the provided keys.
      def provenance_string(provenance, *keys)
        keys.map { |key| provenance[key] }.find { |value| !blank?(value) }&.to_s
      end

      # Returns the trusted publishing flag for a version payload.
      def trusted_publishing?(provenance, version)
        truthy?(provenance["trusted_publishing"]) || truthy?(version["trusted_publishing"])
      end

      # Returns the extracted provenance attributes.
      def provenance_attributes(provenance)
        {
          repository: provenance_string(provenance, "repository", "repository_url", "source_repository"),
          ref: provenance_string(provenance, "ref", "source_ref", "git_ref", "tag"),
          workflow: provenance_string(provenance, "workflow", "workflow_name"),
          issuer: provenance_string(provenance, "issuer"),
          subject: provenance_string(provenance, "subject"),
          sha256: provenance_string(provenance, "sha256", "checksum", "digest"),
          attestation_url: provenance_string(provenance, "attestation_url", "provenance_url", "url")
        }
      end

      # Returns true when +value+ looks truthy in API payload form.
      def truthy?(value)
        value == true || value.to_s.casecmp("true").zero?
      end

      # GETs +path+ from the configured host and returns the response body.
      def get(path)
        uri = URI("#{@host}#{path}")
        response = @http.get_response(uri)
        return response.body if response.is_a?(Net::HTTPSuccess)

        raise Error, "GET #{uri} failed with #{response.code} #{response.message}"
      end

      # Compares a RubyGems platform string with the requested platform.
      def platform_matches?(remote_platform, wanted_platform)
        normalized_remote = remote_platform.to_s.empty? ? "ruby" : remote_platform.to_s
        normalized_wanted = wanted_platform.to_s.empty? ? "ruby" : wanted_platform.to_s
        normalized_remote == normalized_wanted
      end

      # Returns true when +value+ is nil or empty.
      def blank?(value)
        value.nil? || value.to_s.empty?
      end
    end
  end
end
