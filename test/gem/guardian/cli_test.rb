# frozen_string_literal: true

require_relative "../../test_helper"

module Gem
  module Guardian
    class CLITest < Minitest::Test
      def test_version
        stdout = StringIO.new
        status = CLI.new(["version"], stdout:).run

        assert_equal 0, status
        assert_equal "#{VERSION}\n", stdout.string
      end

      def test_unknown_command
        stderr = StringIO.new
        status = CLI.new(["wat"], stderr:).run

        assert_equal 2, status
        assert_match(/Unknown command/, stderr.string)
      end
    end
  end
end
