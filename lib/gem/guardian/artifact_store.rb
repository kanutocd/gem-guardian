# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Gem
  module Guardian
    class ArtifactStore
      def initialize(client:, cache_dir: File.join(Dir.tmpdir, "gem-guardian"))
        @client = client
        @cache_dir = cache_dir
      end

      def path_for(dependency)
        FileUtils.mkdir_p(@cache_dir)
        path = File.join(@cache_dir, dependency.gem_filename)
        return path if File.file?(path)

        @client.download_gem(dependency, path)
      end
    end
  end
end
