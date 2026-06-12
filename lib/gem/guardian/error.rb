# frozen_string_literal: true

module Gem
  module Guardian
    # Base error type for gem-guardian failures.
    Error = Class.new(StandardError)
    # Raised when RubyGems does not expose a checksum for a gem version.
    ChecksumNotFound = Class.new(Error)
    # Raised when downloading or writing a gem artifact fails.
    ArtifactFetchError = Class.new(Error)
    # Raised when a lockfile cannot be read or parsed.
    LockfileError = Class.new(Error)
  end
end
