# frozen_string_literal: true

module Gem
  module Guardian
    # A gem dependency identified by name, version, and platform.
    Dependency = Data.define(:name, :version, :platform, :source) do
      def initialize(name:, version:, platform:, source: nil)
        super
      end

      # Returns the canonical .gem filename for this dependency.
      def gem_filename
        platform_suffix = platform && platform != "ruby" ? "-#{platform}" : ""
        "#{name}-#{version}#{platform_suffix}.gem"
      end
    end
  end
end
