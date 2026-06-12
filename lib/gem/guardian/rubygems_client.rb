# frozen_string_literal: true

require "json"
require "openssl"
require "net/http"
require "uri"

module Gem
  module Guardian
    # Reads checksum metadata from RubyGems.org and downloads gem artifacts.
    # rubocop:disable Metrics/ClassLength
    class RubygemsClient
      # Trusted Publishing provenance metadata extracted from RubyGems version data.
      TrustedPublishingProvenance = Data.define(
        :trusted_publishing, :repository, :ref, :workflow, :issuer, :subject, :sha256, :attestation_url
      )

      SOURCE_COMMIT_PATTERN = %r{Source Commit\s+([A-Za-z0-9._/-]+@[A-Za-z0-9._-]+)}i
      BUILD_FILE_PATTERN = /Build File\s+([^\s]+)/i
      LOG_ENTRY_PATTERN = %r{transparency log entry\s*(https?://[^\s]+)}i
      SHA256_PATTERN = /SHA 256 checksum\s*([a-f0-9]{64})/i
      WORKFLOW_PATTERN = /
        Built and signed on\s+
        ([A-Za-z0-9 ._-]+?)
        (?:\s+Build summary|\s+Source Commit|\z)
      /ix

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
        version && provenance_for(version) ||
          attestation_api_provenance(dependency) ||
          version_page_provenance(dependency)
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
        return unless provenance.any?

        TrustedPublishingProvenance.new(**provenance_attributes(provenance).merge(trusted_publishing: true))
      end

      # Reads provenance details from the RubyGems version page HTML.
      def version_page_provenance(dependency)
        html = get("/gems/#{dependency.name}/versions/#{dependency.version}")
        provenance = html_provenance_payload(html)
        return unless provenance

        TrustedPublishingProvenance.new(**provenance.merge(trusted_publishing: true))
      rescue StandardError
        nil
      end

      # Reads provenance details from the RubyGems attestations API.
      def attestation_api_provenance(dependency)
        attestation_id = dependency.gem_filename.delete_suffix(".gem")
        attestations = JSON.parse(get("/api/v1/attestations/#{attestation_id}.json"))
        attestations.each do |attestation|
          provenance = attestation_bundle_provenance(attestation)
          return TrustedPublishingProvenance.new(**provenance.merge(trusted_publishing: true)) if provenance
        end
        nil
      rescue StandardError
        nil
      end

      # Returns the provenance payload from a version hash.
      def provenance_payload(version)
        payload = version["provenance"] || version["trusted_publishing"] || version["attestation"]
        payload = deep_find_provenance_hash(version) unless payload.is_a?(Hash)
        payload = version if payload.nil? && trusted_publishing_flag?(version)
        payload.is_a?(Hash) ? payload : {}
      end

      # Returns the first non-empty provenance string value for the provided keys.
      def provenance_string(provenance, *keys)
        keys.map { |key| provenance[key] }.find { |value| !blank?(value) }&.to_s
      end

      # Returns the extracted provenance attributes.
      def provenance_attributes(provenance)
        {
          repository: provenance_string(provenance, "repository", "repository_url", "source_repository"),
          ref: provenance_string(provenance, "ref", "source_ref", "git_ref", "tag", "source_commit"),
          workflow: provenance_string(provenance, "workflow", "workflow_name", "build_file"),
          issuer: provenance_string(provenance, "issuer"),
          subject: provenance_string(provenance, "subject"),
          sha256: provenance_string(provenance, "sha256", "checksum", "digest"),
          attestation_url: provenance_string(provenance, "attestation_url", "provenance_url", "url",
                                             "transparency_log_entry")
        }
      end

      # Extracts provenance metadata from the visible RubyGems HTML page text.
      # rubocop:disable Metrics/MethodLength
      def html_provenance_payload(html)
        text = normalized_text(html)
        source_commit = capture_text(text, SOURCE_COMMIT_PATTERN)
        build_file = capture_text(text, BUILD_FILE_PATTERN)
        log_entry = capture_text(text, LOG_ENTRY_PATTERN)
        sha256 = capture_text(text, SHA256_PATTERN)
        workflow = capture_text(text, WORKFLOW_PATTERN)
        return unless source_commit || build_file || log_entry || sha256 || workflow

        repository, ref = parse_source_commit(source_commit)
        {
          repository:,
          ref:,
          workflow: workflow || "GitHub Actions",
          issuer: "GitHub Actions",
          subject: source_commit,
          sha256: sha256,
          attestation_url: log_entry
        }
      end
      # rubocop:enable Metrics/MethodLength

      # Extracts provenance metadata from a Sigstore attestation bundle.
      def attestation_bundle_provenance(attestation)
        bundle = attestation.is_a?(Hash) ? attestation : JSON.parse(attestation.to_s)
        certificate = find_certificate(bundle)
        return unless certificate

        parse_attestation_certificate(certificate)
      end

      # Returns a provenance hash extracted from a leaf certificate.
      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def parse_attestation_certificate(certificate)
        cert = certificate.is_a?(OpenSSL::X509::Certificate) ? certificate : OpenSSL::X509::Certificate.new(certificate)
        extensions = cert.extensions.each_with_object({}) do |ext, memo|
          memo[ext.oid] = ext.value
        end

        repo = extensions["1.3.6.1.4.1.57264.1.5"]
        commit = extensions["1.3.6.1.4.1.57264.1.3"]
        ref = extensions["1.3.6.1.4.1.57264.1.14"]
        build_summary_url = extensions["1.3.6.1.4.1.57264.1.21"]
        san = extensions["subjectAltName"]
        build_file = build_file_from_subject_alt_name(san, repo, ref)

        return unless repo || commit || ref || build_summary_url || build_file

        {
          repository: normalize_repository(repo),
          ref: commit || ref,
          workflow: build_file || build_summary_url,
          issuer: "https://token.actions.githubusercontent.com",
          subject: [repo, commit].compact.join("@"),
          sha256: nil,
          attestation_url: build_summary_url
        }
      rescue OpenSSL::X509::CertificateError, OpenSSL::ASN1::ASN1Error
        nil
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # Finds the first certificate-like payload in a nested attestation bundle.
      # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity
      def find_certificate(value)
        case value
        when String
          return value if value.include?("BEGIN CERTIFICATE")
        when Hash
          value.each_value do |child|
            found = find_certificate(child)
            return found if found
          end
        when Array
          value.each do |child|
            found = find_certificate(child)
            return found if found
          end
        end
        nil
      end
      # rubocop:enable Metrics/MethodLength, Metrics/CyclomaticComplexity

      # Extracts the workflow file path from the SAN extension.
      def build_file_from_subject_alt_name(san, repo, ref)
        return unless san && repo && ref

        match = san.match(%r{\AURI:https://github\.com/#{Regexp.escape(repo)}/(.+)@#{Regexp.escape(ref)}\z})
        match && match[1]
      end

      # Normalizes the repository value to a full GitHub URL.
      def normalize_repository(repository)
        return if blank?(repository)

        repository = repository.to_s
        repository.start_with?("http") ? repository : "https://github.com/#{repository}"
      end

      # Returns a text-only version of the RubyGems HTML page.
      def normalized_text(html)
        html.to_s
            .gsub(%r{<script.*?</script>}m, " ")
            .gsub(%r{<style.*?</style>}m, " ")
            .gsub(/<[^>]+>/, " ")
            .gsub(/&nbsp;/, " ")
            .gsub(/&amp;/, "&")
            .gsub(/\s+/, " ")
      end

      # Captures the first matching string from +text+ for +pattern+.
      def capture_text(text, pattern)
        match = text.match(pattern)
        match && match[1].to_s.strip
      end

      # Returns repository and ref values from a source commit string.
      def parse_source_commit(source_commit)
        return [nil, nil] if blank?(source_commit)

        repository, ref = source_commit.split("@", 2)
        [repository.start_with?("http") ? repository : "https://github.com/#{repository}", ref]
      end

      # Finds a nested provenance hash inside a RubyGems version payload.
      # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity
      def deep_find_provenance_hash(value)
        case value
        when Hash
          return value if provenance_hash?(value)

          value.each_value do |child|
            found = deep_find_provenance_hash(child)
            return found if found
          end
        when Array
          value.each do |child|
            found = deep_find_provenance_hash(child)
            return found if found
          end
        end
        nil
      end
      # rubocop:enable Metrics/MethodLength, Metrics/CyclomaticComplexity

      # Returns true when +value+ looks like a provenance record.
      def provenance_hash?(value)
        (value.keys & %w[
          repository repository_url source_repository ref source_ref git_ref tag source_commit workflow
          workflow_name build_file issuer subject sha256 checksum digest attestation_url provenance_url url
          transparency_log_entry
        ]).any?
      end

      # Returns true when the version payload advertises Trusted Publishing.
      def trusted_publishing_flag?(version)
        value = version["trusted_publishing"]
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
    # rubocop:enable Metrics/ClassLength
  end
end
