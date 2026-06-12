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

            CHECKSUMS
              rake (13.2.1) sha256=#{"a" * 64}
              nokogiri (1.18.9-x86_64-linux) sha256=#{"b" * 64}

            PLATFORMS
              x86_64-linux
          LOCK

          lockfile = LockfileParser.new(path).parse

          assert_equal 2, lockfile.dependencies.size
          assert_equal Dependency.new(name: "rake", version: "13.2.1", platform: "ruby"), lockfile.dependencies[0]
          assert_equal Dependency.new(name: "nokogiri", version: "1.18.9", platform: "x86_64-linux"),
                       lockfile.dependencies[1]
          assert_equal "a" * 64, lockfile.checksum_for(lockfile.dependencies[0])
          assert_equal "b" * 64, lockfile.checksum_for(lockfile.dependencies[1])
          assert_equal [], lockfile.missing_checksum_dependencies
        end
      end

      def test_reports_missing_checksums
        Dir.mktmpdir do |dir|
          path = File.join(dir, "Gemfile.lock")
          File.write(path, <<~LOCK)
            GEM
              remote: https://rubygems.org/
              specs:
                rake (13.2.1)
                nokogiri (1.18.9-x86_64-linux)

            CHECKSUMS
              rake (13.2.1) sha256=#{"a" * 64}

            PLATFORMS
              x86_64-linux
          LOCK

          lockfile = LockfileParser.new(path).parse

          assert_equal 2, lockfile.dependencies.size
          assert lockfile.checksums_present?
          assert_equal 1, lockfile.missing_checksum_dependencies.size
          assert_equal Dependency.new(name: "nokogiri", version: "1.18.9", platform: "x86_64-linux"),
                       lockfile.missing_checksum_dependencies.first
        end
      end

      def test_reports_missing_checksums_section_absence
        Dir.mktmpdir do |dir|
          path = File.join(dir, "Gemfile.lock")
          File.write(path, <<~LOCK)
            GEM
              remote: https://rubygems.org/
              specs:
                rake (13.2.1)

            PLATFORMS
              ruby
          LOCK

          lockfile = LockfileParser.new(path).parse

          refute lockfile.checksums_present?
          assert_equal 1, lockfile.missing_checksum_dependencies.size
        end
      end

      def test_ignores_malformed_checksum_pairs
        Dir.mktmpdir do |dir|
          path = File.join(dir, "Gemfile.lock")
          File.write(path, <<~LOCK)
            GEM
              remote: https://rubygems.org/
              specs:
                rake (13.2.1)

            CHECKSUMS
              rake (13.2.1) sha256=#{"a" * 64},broken=

            PLATFORMS
              ruby
          LOCK

          lockfile = LockfileParser.new(path).parse

          assert_equal "a" * 64,
                       lockfile.checksums[Dependency.new(name: "rake", version: "13.2.1", platform: "ruby")]["sha256"]
          assert_equal 1, lockfile.sha256_checksums.size
        end
      end

      def test_raises_for_missing_lockfile
        error = assert_raises(LockfileError) { LockfileParser.new("missing.lock").dependencies }
        assert_match(/Lockfile not found/, error.message)
      end
    end
  end
end
