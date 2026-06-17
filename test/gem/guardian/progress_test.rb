# frozen_string_literal: true

require_relative "../../test_helper"

module Gem
  module Guardian
    class ProgressTest < Minitest::Test
      class TtyStringIO < StringIO
        def tty?
          true
        end
      end

      def test_update_and_finish_render_single_line_for_tty
        io = TtyStringIO.new

        Progress.update("Downloading long-artifact-name.gem", io:)
        Progress.update("Done", io:)
        Progress.finish(io:)

        assert_equal "\rDownloading long-artifact-name.gem\rDone                              \n", io.string
      end

      def test_progress_is_silent_for_non_tty_streams
        io = StringIO.new

        Progress.update("Downloading", io:)
        Progress.finish("Done", io:)

        assert_empty io.string
      end

      def test_force_renders_for_non_tty_streams
        io = StringIO.new

        Progress.update("Downloading", io:, force: true)
        Progress.finish("Done", io:, force: true)
        assert_equal "\rDownloading\rDone", io.string.rstrip
      end
    end
  end
end
