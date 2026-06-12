# frozen_string_literal: true

module Gem
  module Guardian
    Dependency = Data.define(:name, :version, :platform) do
      def gem_filename
        platform_suffix = platform && platform != "ruby" ? "-#{platform}" : ""
        "#{name}-#{version}#{platform_suffix}.gem"
      end
    end
  end
end
