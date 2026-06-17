# frozen_string_literal: true

require "json"
require "openssl"
require "bundler"
require "gem/guardian/progress"
require "gem/guardian/checksum_provider"
require "fileutils"
require "net/http"
require "rubygems/dependency"
require "rubygems/spec_fetcher"
require "uri"

module Gem
  module Guardian
    # Resolves gem sources, reads registry metadata, and downloads gem artifacts.
    #
    # The client deliberately separates source discovery, checksum-provider lookup,
    # provenance lookup, and artifact download. This lets gem-guardian support
    # RubyGems.org, RubyGems-compatible private registries, and publisher-provided
    # checksum URLs without coupling verification to one registry API.
    # rubocop:disable Metrics/ClassLength
    class RubygemsClient
      # Trusted Publishing provenance metadata extracted from RubyGems version data.
      TrustedPublishingProvenance = Data.define(
        :trusted_publishing, :repository, :ref, :workflow, :issuer, :subject, :sha256, :attestation_url
      )

      # Matches the `Source Commit` field on the RubyGems provenance page.
      SOURCE_COMMIT_PATTERN = %r{Source Commit\s+([A-Za-z0-9._/-]+@[A-Za-z0-9._-]+)}i
      # Matches the `Build File` field on the RubyGems provenance page.
      BUILD_FILE_PATTERN = /Build File\s+([^\s]+)/i
      # Matches the transparency log URL shown on the RubyGems provenance page.
      LOG_ENTRY_PATTERN = %r{transparency log entry\s*(https?://[^\s]+)}i
      # Matches the SHA256 checksum shown on the RubyGems provenance page.
      SHA256_PATTERN = /SHA 256 checksum\s*([a-f0-9]{64})/i
      # Matches the provenance workflow label shown on the RubyGems provenance page.
      WORKFLOW_PATTERN = /
        Built and signed on\s+
        ([A-Za-z0-9 ._-]+?)
        (?:\s+Build summary|\s+Source Commit|\z)
      /ix

      # Default RubyGems.org endpoint used by the client.
      DEFAULT_HOST = "https://rubygems.org"
      # Maximum number of HTTP redirects followed for API and artifact requests.
      MAX_REDIRECTS = 5
      # Connection timeout, in seconds, for direct HTTP requests.
      OPEN_TIMEOUT = 10
      # Read timeout, in seconds, for direct HTTP requests.
      READ_TIMEOUT = 30

      # @param host [String] default RubyGems host used for API requests when a dependency has no source
      # @param http [#get_response] HTTP client used for metadata and artifact requests
      # @param credentials [Object] Bundler settings-like object used to resolve source credentials
      # @param spec_fetcher [Gem::SpecFetcher] RubyGems spec fetcher used for source discovery
      # @param sources [Gem::SourceList, Array<Gem::Source>] configured RubyGems sources
      # @param checksum_providers [Array<#checksum_for>, nil] ordered checksum providers.
      #   Defaults to RubyGems API and compact index providers.
      def initialize(host: DEFAULT_HOST, http: Net::HTTP, credentials: Bundler.settings,
                     spec_fetcher: Gem::SpecFetcher.fetcher, sources: Gem.sources,
                     checksum_providers: nil)
        @host = host.delete_suffix("/")
        @http = http
        @credentials = credentials
        @spec_fetcher = spec_fetcher
        @sources = sources
        @checksum_providers = checksum_providers || default_checksum_providers
      end

      # Returns +dependency+ with its source populated from the configured RubyGems sources.
      #
      # @param dependency [Dependency] dependency that may not include a source URI
      # @return [Dependency] dependency with a sanitized source URI when resolution succeeds
      #
      # Explicit verification starts with a source-less dependency, unlike Bundler lockfile
      # verification where Bundler has already recorded the remote. Resolving through
      # RubyGems keeps gem-guardian aligned with `gem install` behavior for private
      # registries such as GitHub Packages, Gemfury, CodeArtifact, or self-hosted
      # RubyGems-compatible servers.
      def resolve_dependency(dependency)
        return dependency unless blank?(dependency.source)

        _spec, source = resolve_spec_and_source(dependency)
        Dependency.new(name: dependency.name, version: dependency.version, platform: dependency.platform,
                       source: sanitized_source_uri(source))
      rescue StandardError
        dependency
      end

      # Returns the expected SHA256 checksum for +dependency+.
      #
      # @param dependency [Dependency] dependency to look up
      # @return [String] SHA256 digest from the first checksum provider that can answer
      # @raise [ChecksumNotFound] when no provider exposes a checksum
      #
      # This compatibility method returns only the digest. Prefer
      # {#registry_checksum} when callers need provider metadata such as the
      # verification URI or provider name.
      def expected_sha256(dependency)
        checksum = registry_checksum(dependency)
        return checksum.sha256 if checksum

        raise ChecksumNotFound,
              "No SHA256 found for #{dependency.name} #{dependency.version} #{dependency.platform}"
      end

      # Returns registry or publisher supplied checksum metadata for +dependency+.
      #
      # @param dependency [Dependency] dependency to look up
      # @return [ChecksumProvider::Result, nil] provider result with SHA256, provider name, and verification URI
      #
      # Providers are tried in order. The first provider that returns a checksum
      # becomes the independent checksum source. This allows RubyGems.org, compact
      # index registries, and publisher-controlled checksum URLs to participate in
      # the same verification flow.
      def registry_checksum(dependency)
        @checksum_providers.each do |provider|
          checksum = provider.checksum_for(dependency, client: self)
          return checksum if checksum
        rescue StandardError
          next
        end

        nil
      end

      # Returns a sanitized URI string suitable for reports.
      #
      # @param uri [URI, String] URI that may contain credentials
      # @return [String] URI with password/token material redacted
      def sanitize_uri(uri)
        sanitized_uri(uri)
      end

      # Returns checksum metadata from the RubyGems.org-style versions API.
      #
      # @param dependency [Dependency] dependency to look up
      # @return [ChecksumProvider::Result, nil] checksum metadata when the versions API exposes SHA256
      def rubygems_api_checksum(dependency)
        version = matching_version(dependency)
        sha = version && version_checksum(version)
        return if blank?(sha)

        ChecksumProvider::Result.new(
          sha256: sha.downcase,
          source: :registry,
          provider: "rubygems-api",
          verification_uri: "#{host_for(dependency).delete_suffix("/")}/api/v1/versions/#{dependency.name}.json"
        )
      rescue StandardError
        nil
      end

      # Returns checksum metadata from the RubyGems/Bundler compact index.
      #
      # @param dependency [Dependency] dependency to look up
      # @return [ChecksumProvider::Result, nil] checksum metadata when the compact index exposes SHA256
      def compact_index_registry_checksum(dependency)
        host = host_for(dependency)
        info_path = "/info/#{dependency.name}"
        info = get(info_path, host:, progress: false)
        sha = compact_index_checksum_for(info, dependency)
        return if blank?(sha)

        ChecksumProvider::Result.new(
          sha256: sha.downcase,
          source: :registry,
          provider: "compact-index",
          verification_uri: "#{host.delete_suffix("/")}#{info_path}"
        )
      rescue StandardError
        nil
      end

      # Returns trusted publishing provenance data for +dependency+ when RubyGems exposes it.
      #
      # @param dependency [Dependency] dependency to inspect
      # @return [TrustedPublishingProvenance, nil] provenance metadata when available
      def trusted_publishing_provenance(dependency)
        return nil unless ruby_gems_org_source?(dependency)

        version = matching_version(dependency)
        version && provenance_for(version) ||
          attestation_api_provenance(dependency) ||
          version_page_provenance(dependency)
      end

      # Downloads the .gem file for +dependency+ into +destination+.
      #
      # @param dependency [Dependency] dependency to resolve and download
      # @param destination [String] path where the downloaded artifact should be written
      # @return [String] destination path
      # @raise [ArtifactFetchError] when source resolution or artifact download fails
      #
      # RubyGems is used for source/spec resolution, but gem-guardian performs the
      # artifact download itself. This keeps verification deterministic, applies
      # explicit HTTP timeouts, avoids RubyGems installer-side behavior, and prevents
      # `Gem::Source#download` from emitting progress output or hanging in internal
      # fetch paths.
      def download_gem(dependency, destination)
        spec, source = resolve_spec_and_source(dependency)
        download_gem_uri(gem_uri(source, spec), destination)
      rescue StandardError => e
        raise ArtifactFetchError, "Could not fetch #{dependency.gem_filename}: #{e.message}"
      end

      private

      def default_checksum_providers
        [ChecksumProvider::RubyGemsApi.new, ChecksumProvider::CompactIndex.new]
      end

      def download_gem_uri(uri, destination)
        Gem::Guardian::Progress.update("Downloading #{File.basename(uri.path)}...")
        response = get_response(uri)
        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "GET #{sanitized_uri(uri)} failed with #{response.code} #{response.message}"
        end

        FileUtils.mkdir_p(File.dirname(destination))
        File.binwrite(destination, response.body)
        Gem::Guardian::Progress.finish("Downloaded #{File.basename(uri.path)}")
        destination
      end

      def gem_uri(source, spec)
        base_uri = URI.parse(source.respond_to?(:uri) ? source.uri.to_s : source.to_s)
        URI.join(base_uri.to_s.end_with?("/") ? base_uri.to_s : "#{base_uri}/", "gems/#{spec_full_name(spec)}.gem")
      end

      def spec_full_name(spec)
        return spec.full_name if spec.respond_to?(:full_name)

        platform = spec.platform.to_s
        segments = [spec.name, spec.version.to_s]
        segments << platform unless platform.empty? || platform == "ruby"
        segments.join("-")
      end

      def resolve_spec_and_source(dependency)
        matches = matching_specs(dependency)
        if matches.empty?
          raise ArtifactFetchError,
                "No source found for #{dependency.name} #{dependency.version} #{dependency.platform}"
        end

        warn_ambiguous_sources(dependency, matches) if matches.size > 1
        matches.first
      end

      def matching_specs(dependency)
        remote_dependency = Gem::Dependency.new(dependency.name, "= #{dependency.version}")
        specs, = @spec_fetcher.spec_for_dependency(remote_dependency, false)
        # rubocop:disable Style/MultilineBlockChain
        specs.select do |spec, source|
          platform_matches?(spec.platform, dependency.platform) && source_matches?(source, dependency.source)
        end.sort_by { |_spec, source| source_order(source) }
        # rubocop:enable Style/MultilineBlockChain
      end

      def warn_ambiguous_sources(dependency, matches)
        sources = matches.map { |_spec, source| sanitized_source_uri(source) }.uniq
        return if sources.size <= 1

        warn "gem-guardian: #{dependency.name} #{dependency.version} #{dependency.platform} found in multiple sources; " \
             "using #{sources.first}"
      end

      def source_order(source)
        source_uri = comparable_source_uri(source)
        configured_sources.index { |configured| comparable_source_uri(configured) == source_uri } || configured_sources.size
      end

      def configured_sources
        @configured_sources ||= @sources.respond_to?(:to_a) ? @sources.to_a : Array(@sources)
      end

      def source_matches?(source, wanted_source)
        return true if blank?(wanted_source)

        comparable_source_uri(source) == comparable_source_uri(wanted_source)
      end

      def comparable_source_uri(source)
        uri = URI.parse(source.respond_to?(:uri) ? source.uri.to_s : source.to_s)
        uri.user = nil
        uri.password = nil
        uri.to_s.delete_suffix("/")
      end

      def sanitized_source_uri(source)
        comparable_source_uri(source)
      end

      def compact_index_checksum_for(info, dependency)
        after_header = false

        info.each_line do |line|
          line = line.strip
          if line == "---"
            after_header = true
            next
          end
          next unless after_header
          next if line.empty?

          version_platform, _metadata = line.split(" ", 2)
          version, platform = compact_version_and_platform(version_platform)
          next unless version == dependency.version && platform_matches?(platform, dependency.platform)

          checksum = line[/[|,]checksum:([a-fA-F0-9]{64})(?:,|$)/, 1]
          return checksum.downcase unless blank?(checksum)
        end

        nil
      end

      def compact_version_and_platform(version_platform)
        version, platform = version_platform.to_s.split("-", 2)
        [version, blank?(platform) ? "ruby" : platform]
      end

      def matching_version(dependency)
        versions = JSON.parse(get("/api/v1/versions/#{dependency.name}.json", host: host_for(dependency), progress: false))
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
        html = get("/gems/#{dependency.name}/versions/#{dependency.version}", host: host_for(dependency), progress: false)
        provenance = html_provenance_payload(html)
        return unless provenance

        TrustedPublishingProvenance.new(**provenance.merge(trusted_publishing: true))
      rescue StandardError
        nil
      end

      # Reads provenance details from the RubyGems attestations API.
      def attestation_api_provenance(dependency)
        attestation_id = dependency.gem_filename.delete_suffix(".gem")
        attestations = JSON.parse(get("/api/v1/attestations/#{attestation_id}.json", host: host_for(dependency), progress: false))
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
      # rubocop:disable Metrics/CyclomaticComplexity
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
      # rubocop:enable Metrics/CyclomaticComplexity

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
      # rubocop:disable Metrics/CyclomaticComplexity
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
      # rubocop:enable Metrics/CyclomaticComplexity

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

      # GETs +path+ from the configured or dependency source host and returns the response body.
      def get(path, host: @host, progress: true)
        uri = URI("#{host.delete_suffix("/")}#{path}")
        Gem::Guardian::Progress.update("Downloading #{File.basename(uri.path)}...") if progress
        response = get_response(uri)
        return response.body if response.is_a?(Net::HTTPSuccess)

        raise Error, "GET #{uri} failed with #{response.code} #{response.message}"
      end

      def get_response(uri, limit: MAX_REDIRECTS)
        raise Error, "Too many redirects for #{uri}" if limit.negative?

        headers = authorization_headers(uri)
        response = if headers.empty?
                     plain_response(uri)
                   else
                     authenticated_response(uri, headers)
                   end
        return redirect_response(response, uri, limit) if response.is_a?(Net::HTTPRedirection)

        response
      end

      def plain_response(uri)
        return @http.get_response(uri) unless @http == Net::HTTP

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: OPEN_TIMEOUT,
                                            read_timeout: READ_TIMEOUT) do |http|
          http.request(Net::HTTP::Get.new(uri.request_uri))
        end
      end

      def authenticated_response(uri, headers)
        request = Net::HTTP::Get.new(uri.request_uri)
        request.instance_variable_set(:@uri, uri)
        headers.each { |key, value| request[key] = value }
        return @http.request(request) if @http.respond_to?(:request)

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: OPEN_TIMEOUT,
                                            read_timeout: READ_TIMEOUT) do |http|
          http.request(request)
        end
      end

      def redirect_response(response, uri, limit)
        location = response["location"]
        raise Error, "Redirect missing location for #{uri}" if blank?(location)

        redirect_uri = URI.parse(URI.join(uri.to_s, location.to_s).to_s)
        get_response(redirect_uri, limit: limit - 1)
      end

      def authorization_headers(uri)
        return {} unless github_packages_host?(uri.host)

        token = bearer_token_for(uri)
        token ? { "Authorization" => "Bearer #{token}" } : {}
      end

      def bearer_token_for(uri)
        embedded_token = uri.password || uri.user
        return embedded_token unless blank?(embedded_token)

        credentials = @credentials.credentials_for(sanitized_uri(uri)) || @credentials.credentials_for(uri)
        return if blank?(credentials)

        credentials.to_s.split(":", 2).last
      rescue StandardError
        nil
      end

      def sanitized_uri(uri)
        sanitized = URI.parse(uri.to_s)
        sanitized.user = nil
        sanitized.password = nil
        sanitized.to_s
      end

      def github_packages_host?(host)
        host.to_s.casecmp("rubygems.pkg.github.com").zero?
      end

      def host_for(dependency)
        source = dependency.respond_to?(:source) && dependency.source
        blank?(source) ? @host : source
      end

      def ruby_gems_org_source?(dependency)
        comparable_source_uri(host_for(dependency)) == comparable_source_uri(DEFAULT_HOST)
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
