# frozen_string_literal: true

require 'json'
require_relative 'managed'

module DevClusters
  module Kb
    # One managed lease translates only the descriptor digest. The dispatcher
    # owns its child PID until waitpid reaps it, including cancellation.
    class Lease
      MAX_READINESS = 8192

      def initialize(argv:, canonical:, managed:, input: $stdin, output: $stdout, error: $stderr)
        @argv, @canonical, @managed = argv, canonical, managed
        @input, @output, @error = input, output, error
        @pid = nil
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def reap
        return @status unless @pid

        result = Process.waitpid2(@pid, Process::WNOHANG)
        if result
          @status = result.last
          @pid = nil
        end
        @status
      end

      def await_exit(seconds)
        deadline = now + seconds
        loop do
          return true if reap
          return false if now >= deadline

          sleep 0.02
        end
      end

      def cleanup
        @child_input&.close unless @child_input&.closed?
        return unless @pid
        return if await_exit(2)

        %w[TERM KILL].each do |signal|
          Process.kill(signal, @pid) if @pid
          return if await_exit(2)
        end
        raise Error, 'KB lease child did not exit within cleanup budget'
      end

      def close_output
        return if @output.closed?

        # Ruby protects standard streams from closing their underlying FD.
        # Reopening deliberately detaches this protocol pipe before close.
        @output.reopen(File::NULL, 'w') if @output.is_a?(IO) && @output.fileno <= 2
        @output.close
      end

      def run
        child_read, @child_input = IO.pipe
        child_output, child_write = IO.pipe
        child_error, error_write = IO.pipe
        @pid = Process.spawn(*@argv, in: child_read, out: child_write, err: error_write, close_others: true)
        [child_read, child_write, error_write].each(&:close)
        deadline = now + 5
        buffer = +''
        pending_input = +''
        ready = false
        peer_closed = false
        protocol_lost = false
        diagnostics_open = true
        loop do
          readable = [child_output]
          readable << child_error if diagnostics_open
          readable << @input unless peer_closed
          writable = pending_input.empty? || @child_input.closed? ? [] : [@child_input]
          readers, writers = IO.select(readable, writable, nil, 0.05)
          if readers&.include?(@input)
            chunk = @input.read_nonblock(1024, exception: false)
            if chunk.nil?
              peer_closed = true
              @child_input.close
              raise Error, 'capture peer ended before readiness' unless ready
              break
            elsif chunk != :wait_readable
              pending_input << chunk
              raise Error, 'capture input exceeds lease buffer' if pending_input.bytesize > MAX_READINESS
            end
          end
          if writers&.include?(@child_input)
            written = @child_input.write_nonblock(pending_input, exception: false)
            pending_input = pending_input.byteslice(written..) if written.is_a?(Integer)
          end
          if readers&.include?(child_error)
            chunk = child_error.read_nonblock(4096, exception: false)
            if chunk.nil?
              diagnostics_open = false
            elsif chunk != :wait_readable
              @error.write(chunk)
              @error.flush
            end
          end
          if readers&.include?(child_output)
            # Drain available bytes and observe EOF independently of parsing.
            # A ready record and EOF in one read window cannot publish a lease.
            loop do
              chunk = child_output.read_nonblock(MAX_READINESS + 1, exception: false)
              break if chunk == :wait_readable
              if chunk.nil?
                protocol_lost = true
                break
              end
              raise Error, 'unexpected additional KB lease protocol output' if ready
              buffer << chunk
              raise Error, 'KB lease readiness exceeds limit' if buffer.bytesize > MAX_READINESS
            end
          end
          raise Error, 'KB lease protocol ended' if protocol_lost
          raise Error, 'KB lease child exited' if reap
          if !ready && buffer.include?("\n")
            line, rest = buffer.split("\n", 2)
            raise Error, 'extra KB lease readiness output' unless rest.empty?
            value = JSON.parse(line)
            raise Error, 'KB canonical lease readiness differs' unless value == @canonical
            @output.write(JSON.generate(value.merge('descriptor_sha256' => @managed)) + "\n")
            @output.flush
            ready = true
            buffer.clear
          end
          raise Error, 'KB lease readiness deadline reached' if !ready && now >= deadline
        end
        close_output
        cleanup
        raise Error, 'KB lease child failed after peer EOF' unless @status&.success?
        true
      rescue JSON::ParserError, IOError, SystemCallError => error
        raise Error, "KB lease transport failed: #{error.message}"
      ensure
        close_output
        cleanup
        [child_read, child_write, error_write, child_output, child_error, @child_input].compact.each do |stream|
          stream.close unless stream.closed?
        end
      end
    end
  end
end
