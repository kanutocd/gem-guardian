# frozen_string_literal: true

require_relative "../../test_helper"

module Gem
  module Guardian
    class ChecksumProviderTest < Minitest::Test
      SuccessResponse = Struct.new(:body) do
        def is_a?(klass)
          klass == Net::HTTPSuccess || super
        end
      end

      FailureResponse = Struct.new(:code, :message) do
        def is_a?(_klass)
          false
        end
      end

      class FakeHTTP
        attr_reader :requests

        def initialize(response)
          @response = response
          @requests = []
        end

        def get_response(uri)
          @requests << uri
          @response
        end
      end

      def test_url_provider_reads_bare_sha256_from_publisher_url
        sha = "a" * 64
        http = FakeHTTP.new(SuccessResponse.new("#{sha}\n"))
        provider = ChecksumProvider::Url.new(
          template: "https://checksums.example/{filename}.sha256",
          http:,
          provider_name: "my-gem-registry-checksums"
        )
        dependency = Dependency.new(name: "mammoth-pro", version: "1.0.0", platform: "ruby")

        result = provider.checksum_for(dependency, client: RubygemsClient.new)

        assert_equal sha, result.sha256
        assert_equal :publisher, result.source
        assert_equal "my-gem-registry-checksums", result.provider
        assert_equal "https://checksums.example/mammoth-pro-1.0.0.gem.sha256", result.verification_uri
      end

      def test_url_provider_reads_sha256_from_checksum_file_line
        sha = "b" * 64
        http = FakeHTTP.new(SuccessResponse.new("#{sha}  mammoth-pro-1.0.0.gem\n"))
        provider = ChecksumProvider::Url.new(
          template: "https://checksums.example/{name}/{version}/{filename}.sha256",
          http:
        )
        dependency = Dependency.new(name: "mammoth-pro", version: "1.0.0", platform: "ruby")

        result = provider.checksum_for(dependency, client: RubygemsClient.new)

        assert_equal sha, result.sha256
        assert_equal "url", result.provider
        assert_equal "https://checksums.example/mammoth-pro/1.0.0/mammoth-pro-1.0.0.gem.sha256",
                     result.verification_uri
      end

      def test_url_provider_returns_nil_for_failed_response
        http = FakeHTTP.new(FailureResponse.new("404", "Not Found"))
        provider = ChecksumProvider::Url.new(template: "https://checksums.example/{filename}.sha256", http:)
        dependency = Dependency.new(name: "mammoth-pro", version: "1.0.0", platform: "ruby")

        assert_nil provider.checksum_for(dependency, client: RubygemsClient.new)
      end

      def test_url_provider_returns_nil_when_no_sha256_is_present
        http = FakeHTTP.new(SuccessResponse.new("no checksum here"))
        provider = ChecksumProvider::Url.new(template: "https://checksums.example/{filename}.sha256", http:)
        dependency = Dependency.new(name: "mammoth-pro", version: "1.0.0", platform: "ruby")

        assert_nil provider.checksum_for(dependency, client: RubygemsClient.new)
      end


      def test_result_to_h_is_json_friendly
        result = ChecksumProvider::Result.new(
          sha256: "c" * 64,
          source: :publisher,
          provider: "custom",
          verification_uri: "https://checksums.example/foo.sha256"
        )

        assert_equal(
          {
            sha256: "c" * 64,
            source: :publisher,
            provider: "custom",
            verification_uri: "https://checksums.example/foo.sha256"
          },
          result.to_h
        )
      end

      def test_rubygems_api_provider_delegates_to_client
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
        client = Object.new
        def client.rubygems_api_checksum(dependency)
          ChecksumProvider::Result.new(
            sha256: "d" * 64,
            source: :registry,
            provider: "rubygems-api",
            verification_uri: "https://rubygems.org/api/v1/versions/rake.json"
          )
        end

        result = ChecksumProvider::RubyGemsApi.new.checksum_for(dependency, client:)

        assert_equal "d" * 64, result.sha256
        assert_equal "rubygems-api", result.provider
      end

      def test_compact_index_provider_delegates_to_client
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
        client = Object.new
        def client.compact_index_registry_checksum(dependency)
          ChecksumProvider::Result.new(
            sha256: "e" * 64,
            source: :registry,
            provider: "compact-index",
            verification_uri: "https://rubygems.org/info/rake"
          )
        end

        result = ChecksumProvider::CompactIndex.new.checksum_for(dependency, client:)

        assert_equal "e" * 64, result.sha256
        assert_equal "compact-index", result.provider
      end

      def test_url_provider_expands_native_platform_placeholder
        sha = "f" * 64
        http = FakeHTTP.new(SuccessResponse.new(sha))
        provider = ChecksumProvider::Url.new(
          template: "https://checksums.example/{name}/{version}/{platform}/{filename}.sha256",
          http:
        )
        dependency = Dependency.new(name: "nokogiri", version: "1.18.9", platform: "x86_64-linux")

        result = provider.checksum_for(dependency, client: RubygemsClient.new)

        assert_equal sha, result.sha256
        assert_equal "https://checksums.example/nokogiri/1.18.9/x86_64-linux/nokogiri-1.18.9-x86_64-linux.gem.sha256",
                     result.verification_uri
      end

      def test_url_provider_returns_nil_for_invalid_url_template
        provider = ChecksumProvider::Url.new(template: "https:// invalid/{filename}.sha256")
        dependency = Dependency.new(name: "mammoth-pro", version: "1.0.0", platform: "ruby")

        assert_nil provider.checksum_for(dependency, client: RubygemsClient.new)
      end

      def test_url_provider_uses_net_http_when_no_custom_http_client_is_supplied
        sha = "1" * 64
        response = SuccessResponse.new("#{sha}  mammoth-pro-1.0.0.gem\n")
        request_paths = []
        start_args = nil

        fake_http = Object.new
        fake_http.define_singleton_method(:request) do |request|
          request_paths << request.path
          response
        end

        singleton = class << Net::HTTP; self; end
        singleton.alias_method :__gem_guardian_original_start, :start
        singleton.define_method(:start) do |host, port, use_ssl:, open_timeout:, read_timeout:, &block|
          start_args = {
            host: host,
            port: port,
            use_ssl: use_ssl,
            open_timeout: open_timeout,
            read_timeout: read_timeout
          }
          block.call(fake_http)
        end

        provider = ChecksumProvider::Url.new(template: "https://checksums.example/{filename}.sha256")
        dependency = Dependency.new(name: "mammoth-pro", version: "1.0.0", platform: "ruby")
        result = provider.checksum_for(dependency, client: RubygemsClient.new)

        assert_equal sha, result.sha256
        assert_equal :publisher, result.source
        assert_equal "url", result.provider
        assert_equal "https://checksums.example/mammoth-pro-1.0.0.gem.sha256", result.verification_uri
        assert_equal ["/mammoth-pro-1.0.0.gem.sha256"], request_paths
        assert_equal(
          {
            host: "checksums.example",
            port: 443,
            use_ssl: true,
            open_timeout: ChecksumProvider::Url::OPEN_TIMEOUT,
            read_timeout: ChecksumProvider::Url::READ_TIMEOUT
          },
          start_args
        )
      ensure
        if singleton&.method_defined?(:__gem_guardian_original_start)
          singleton.alias_method :start, :__gem_guardian_original_start
          singleton.remove_method :__gem_guardian_original_start
        end
      end
    end
  end
end
