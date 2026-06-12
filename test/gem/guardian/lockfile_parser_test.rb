# frozen_string_literal: true

require_relative "../../test_helper"

module Gem
  module Guardian
    class LockfileParserTest < Minitest::Test
      def test_parses_ruby_and_platform_gems
        Dir.mktmpdir do |dir|
          path = File.join(dir, "Gemfile.lock")
          File.write(path, <<~LOCK)
            GEM
              remote: https://rubygems.org/
              specs:
                rake (13.2.1)
                nokogiri (1.18.9-x86_64-linux)
                  racc (~> 1.4)

            PLATFORMS
              x86_64-linux
          LOCK

          deps = LockfileParser.new(path).dependencies

          assert_equal 2, deps.size
          assert_equal Dependency.new(name: "rake", version: "13.2.1", platform: "ruby"), deps[0]
          assert_equal Dependency.new(name: "nokogiri", version: "1.18.9", platform: "x86_64-linux"), deps[1]
        end
      end

      def test_raises_for_missing_lockfile
        error = assert_raises(LockfileError) { LockfileParser.new("missing.lock").dependencies }
        assert_match(/Lockfile not found/, error.message)
      end
    end
  end
end
