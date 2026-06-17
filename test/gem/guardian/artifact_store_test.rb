# frozen_string_literal: true

require_relative "../../test_helper"

module Gem
  module Guardian
    class ArtifactStoreTest < Minitest::Test
      FakeClient = Struct.new(:downloaded, keyword_init: true) do
        def download_gem(dependency, destination)
          self.downloaded = [dependency, destination]
          File.binwrite(destination, "downloaded")
          destination
        end
      end

      def test_path_for_returns_cached_file_without_downloading
        Dir.mktmpdir do |dir|
          dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
          path = File.join(dir, dependency.gem_filename)
          File.binwrite(path, "cached")
          client = FakeClient.new(downloaded: nil)

          store = ArtifactStore.new(client:, cache_dir: dir)
          assert_equal path, store.path_for(dependency)
          assert_nil client.downloaded
        end
      end

      def test_path_for_downloads_missing_file
        Dir.mktmpdir do |dir|
          dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")
          client = FakeClient.new(downloaded: nil)

          store = ArtifactStore.new(client:, cache_dir: dir)
          path = store.path_for(dependency)

          assert_equal File.join(dir, dependency.gem_filename), path
          assert_equal [dependency, path], client.downloaded
          assert_equal "downloaded", File.binread(path)
        end
      end


      def test_path_for_uses_source_specific_cache_directory
        Dir.mktmpdir do |dir|
          dependency = Dependency.new(name: "private-gem", version: "1.0.0", platform: "ruby",
                                      source: "https://rubygems.pkg.github.com/kanutocd")
          client = FakeClient.new(downloaded: nil)

          store = ArtifactStore.new(client:, cache_dir: dir)
          path = store.path_for(dependency)

          refute_equal File.join(dir, dependency.gem_filename), path
          assert_match(%r{/private-gem-1\.0\.0\.gem\z}, path)
          assert_equal [dependency, path], client.downloaded
        end
      end


      def test_path_for_treats_empty_source_as_default_cache_directory
        Dir.mktmpdir do |dir|
          dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby", source: "")
          client = FakeClient.new(downloaded: nil)

          store = ArtifactStore.new(client:, cache_dir: dir)
          path = store.path_for(dependency)

          assert_equal File.join(dir, dependency.gem_filename), path
        end
      end

    end
  end
end
