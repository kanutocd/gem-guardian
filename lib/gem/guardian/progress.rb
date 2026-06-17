# frozen_string_literal: true

module Gem
  module Guardian
    # Minimal single-line terminal progress helper.
    #
    # Progress output is intentionally disabled for non-TTY streams so JSON output,
    # CI logs, and tests do not receive carriage-return noise. Interactive terminals
    # get in-place updates via `\r`; callers should use +finish+ when a logical step
    # is complete and a newline should be emitted.
    module Progress
      module_function

      @last_width = 0

      # Writes or refreshes an in-place progress message.
      #
      # The message is rendered with a carriage return so repeated calls update
      # the same terminal line. If a later message is shorter than the previous
      # one, trailing characters are cleared with spaces. Output is skipped for
      # non-TTY streams unless +force+ is true, which keeps JSON output and CI logs
      # clean.
      #
      # @param message [#to_s] progress text to render
      # @param io [IO] stream that receives the progress message
      # @param force [Boolean] when true, writes even if +io+ is not a TTY
      # @return [void] returns no value; writes progress as a side effect
      def update(message, io: $stdout, force: false)
        return unless enabled?(io, force:)

        message = message.to_s
        padding = " " * [@last_width - message.length, 0].max
        io.print "\r#{message}#{padding}"
        io.flush
        @last_width = message.length
      end

      # Completes the current progress line and emits a newline.
      #
      # Call this after a logical step finishes so the next human-readable result
      # starts on a clean line. When +message+ is provided, the line is refreshed
      # one final time before the newline is written.
      #
      # @param message [#to_s, nil] optional final message for the progress line
      # @param io [IO] stream that receives the progress message
      # @param force [Boolean] when true, writes even if +io+ is not a TTY
      # @return [void] returns no value; writes a final progress line as a side effect
      def finish(message = nil, io: $stdout, force: false)
        return unless enabled?(io, force:)

        update(message, io:, force:) if message
        io.puts
        @last_width = 0
      end

      # Returns whether progress output should be written to the provided stream.
      #
      # @param io [IO] candidate progress stream
      # @param force [Boolean] bypasses TTY detection when true
      # @return [Boolean] +true+ when progress output should be emitted
      def enabled?(io = $stdout, force: false)
        force || (io.respond_to?(:tty?) && io.tty?)
      end
    end
  end
end
