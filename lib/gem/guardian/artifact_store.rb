# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Gem
  module Guardian
    # Stores downloaded gem artifacts in a local cache directory.
    class ArtifactStore
      # @param client [RubygemsClient] downloader used when the artifact is not cached
      # @param cache_dir [String] directory where downloaded artifacts are stored
      def initialize(client:, cache_dir: File.join(Dir.tmpdir, "gem-guardian"))
        @client = client
        @cache_dir = cache_dir
      end

      # Returns the local path for +dependency+, downloading it if needed.
      def path_for(dependency)
        FileUtils.mkdir_p(@cache_dir)
        path = File.join(@cache_dir, dependency.gem_filename)
        return path if File.file?(path)

        @client.download_gem(dependency, path)
      end
    end
  end
end
