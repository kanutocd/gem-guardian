# frozen_string_literal: true

require_relative "../../test_helper"

module Gem
  module Guardian
    class DependencyTest < Minitest::Test
      def test_gem_filename_for_ruby_platform
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")

        assert_equal "rake-13.2.1.gem", dependency.gem_filename
      end

      def test_gem_filename_for_native_platform
        dependency = Dependency.new(name: "nokogiri", version: "1.18.9", platform: "x86_64-linux")

        assert_equal "nokogiri-1.18.9-x86_64-linux.gem", dependency.gem_filename
      end

      def test_gem_filename_handles_nil_platform
        dependency = Dependency.new(name: "rake", version: "13.2.1", platform: nil)

        assert_equal "rake-13.2.1.gem", dependency.gem_filename
      end
    end
  end
end
