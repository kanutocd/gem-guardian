# frozen_string_literal: true

require "json"

require_relative "../../test_helper"

module Gem
  module Guardian
    class GitHubClientTest < Minitest::Test
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
        def initialize(response_map)
          @response_map = response_map
        end

        def get_response(uri)
          @response_map.fetch(uri.path)
        end
      end

      def test_release_returns_payload
        client = GitHubClient.new(http: FakeHTTP.new(
                                   "/repos/kanutocd/gem-guardian/releases/tags/v0.1.1" => SuccessResponse.new(
                                     JSON.dump("tag_name" => "v0.1.1")
                                   )
                                 ))

        assert_equal({ "tag_name" => "v0.1.1" }, client.release("kanutocd/gem-guardian", "v0.1.1"))
      end

      def test_release_returns_nil_on_http_error
        client = GitHubClient.new(http: FakeHTTP.new(
                                   "/repos/kanutocd/gem-guardian/releases/tags/v0.1.1" => FailureResponse.new("404", "Not Found")
                                 ))

        assert_nil client.release("kanutocd/gem-guardian", "v0.1.1")
      end

      def test_tag_verification_uses_tag_object_verification
        client = GitHubClient.new(http: FakeHTTP.new(
                                   "/repos/kanutocd/gem-guardian/git/ref/tags/v0.1.1" => SuccessResponse.new(
                                     JSON.dump(
                                       "object" => {
                                         "type" => "tag",
                                         "verification" => { "verified" => true, "reason" => "valid" }
                                       }
                                     )
                                   )
                                 ))

        verification = client.tag_verification("kanutocd/gem-guardian", "v0.1.1")

        assert_equal true, verification["verified"]
        assert_equal "valid", verification["reason"]
      end

      def test_tag_verification_falls_back_to_commit_verification
        client = GitHubClient.new(http: FakeHTTP.new(
                                   "/repos/kanutocd/gem-guardian/git/ref/tags/v0.1.1" => SuccessResponse.new(
                                     JSON.dump(
                                       "object" => {
                                         "type" => "commit",
                                         "sha" => "abc123"
                                       }
                                     )
                                   ),
                                   "/repos/kanutocd/gem-guardian/commits/abc123" => SuccessResponse.new(
                                     JSON.dump(
                                       "commit" => {
                                         "verification" => { "verified" => true, "reason" => "valid" }
                                       }
                                     )
                                   )
                                 ))

        verification = client.tag_verification("kanutocd/gem-guardian", "v0.1.1")

        assert_equal true, verification["verified"]
      end

      def test_tag_verification_returns_nil_when_commit_verification_is_missing
        client = GitHubClient.new(http: FakeHTTP.new(
                                   "/repos/kanutocd/gem-guardian/git/ref/tags/v0.1.1" => SuccessResponse.new(
                                     JSON.dump(
                                       "object" => {
                                         "type" => "commit",
                                         "sha" => "abc123"
                                       }
                                     )
                                   ),
                                   "/repos/kanutocd/gem-guardian/commits/abc123" => SuccessResponse.new(
                                     JSON.dump("commit" => {})
                                   )
                                 ))

        assert_nil client.tag_verification("kanutocd/gem-guardian", "v0.1.1")
      end

      def test_tag_verification_returns_nil_for_malformed_payloads
        client = GitHubClient.new(http: FakeHTTP.new(
                                   "/repos/kanutocd/gem-guardian/git/ref/tags/v0.1.1" => SuccessResponse.new(
                                     JSON.dump([])
                                   )
                                 ))

        assert_nil client.tag_verification("kanutocd/gem-guardian", "v0.1.1")

        client = GitHubClient.new(http: FakeHTTP.new(
                                   "/repos/kanutocd/gem-guardian/git/ref/tags/v0.1.1" => SuccessResponse.new(
                                     JSON.dump("object" => "oops")
                                   )
                                 ))

        assert_nil client.tag_verification("kanutocd/gem-guardian", "v0.1.1")
      end


      def test_tag_verification_returns_nil_when_commit_payload_is_not_hash
        client = GitHubClient.new(http: FakeHTTP.new(
                                   "/repos/kanutocd/gem-guardian/git/ref/tags/v0.1.1" => SuccessResponse.new(
                                     JSON.dump(
                                       "object" => {
                                         "type" => "commit",
                                         "sha" => "abc123"
                                       }
                                     )
                                   ),
                                   "/repos/kanutocd/gem-guardian/commits/abc123" => SuccessResponse.new(JSON.dump([]))
                                 ))

        assert_nil client.tag_verification("kanutocd/gem-guardian", "v0.1.1")
      end

      def test_tag_verification_returns_nil_when_commit_hash_lacks_commit_key
        client = GitHubClient.new(http: FakeHTTP.new(
                                   "/repos/kanutocd/gem-guardian/git/ref/tags/v0.1.1" => SuccessResponse.new(
                                     JSON.dump(
                                       "object" => {
                                         "type" => "commit",
                                         "sha" => "abc123"
                                       }
                                     )
                                   ),
                                   "/repos/kanutocd/gem-guardian/commits/abc123" => SuccessResponse.new(JSON.dump("other" => {}))
                                 ))

        assert_nil client.tag_verification("kanutocd/gem-guardian", "v0.1.1")
      end


      def test_tag_verification_returns_nil_when_tag_verification_is_not_hash
        client = GitHubClient.new(http: FakeHTTP.new(
                                   "/repos/kanutocd/gem-guardian/git/ref/tags/v0.1.1" => SuccessResponse.new(
                                     JSON.dump(
                                       "object" => {
                                         "type" => "tag",
                                         "sha" => "abc123",
                                         "verification" => "not-a-hash"
                                       }
                                     )
                                   ),
                                   "/repos/kanutocd/gem-guardian/commits/abc123" => SuccessResponse.new(JSON.dump([]))
                                 ))

        assert_nil client.tag_verification("kanutocd/gem-guardian", "v0.1.1")
      end

      def test_release_returns_nil_for_malformed_json
        client = GitHubClient.new(http: FakeHTTP.new(
                                   "/repos/kanutocd/gem-guardian/releases/tags/v0.1.1" => SuccessResponse.new("not json")
                                 ))

        assert_nil client.release("kanutocd/gem-guardian", "v0.1.1")
      end
    end
  end
end
