# frozen_string_literal: true

require "digest"

module Gem
  module Guardian
    # Local checksum helpers.
    module Checksum
      module_function

      # Returns the SHA256 hex digest for the file at +path+.
      def sha256_file(path)
        Digest::SHA256.file(path).hexdigest
      end
    end
  end
end
