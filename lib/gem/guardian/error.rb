# frozen_string_literal: true

module Gem
  module Guardian
    Error = Class.new(StandardError)
    ChecksumNotFound = Class.new(Error)
    ArtifactFetchError = Class.new(Error)
    LockfileError = Class.new(Error)
  end
end
