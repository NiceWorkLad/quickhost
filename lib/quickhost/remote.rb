require "open3"
require "shellwords"

module Quickhost
  # Runs commands on the server over ssh. In dry-run mode it only prints them.
  class Remote
    Result = Struct.new(:ok, :out, :err) do
      def ok? = ok
    end

    attr_reader :server, :log

    def initialize(server, dry_run: false, out: $stdout)
      @server = server
      @dry_run = dry_run
      @out = out
      @log = []
    end

    def dry_run? = @dry_run

    # Run a remote command given as an argv array. Returns Result.
    # stream: true echoes output live (for docker build).
    # input:  path of a local file piped to the command's stdin.
    def run(*argv, input: nil, stream: false, allow_fail: false)
      cmd = Shellwords.join(argv.flatten.map(&:to_s))
      @log << cmd
      if dry_run?
        @out.puts "  $ #{cmd}#{input ? " < #{File.basename(input)}" : ''}"
        return Result.new(true, "", "")
      end

      ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", server, cmd]
      result = stream ? run_streaming(ssh, input) : run_captured(ssh, input)
      if !result.ok? && !allow_fail
        raise Error, "Command failed on #{server}: #{cmd}\n#{result.err.strip}"
      end

      result
    end

    private

    def run_captured(ssh, input)
      out, err, status =
        if input
          File.open(input, "rb") { |f| Open3.capture3(*ssh, stdin_data: f.read, binmode: true) }
        else
          Open3.capture3(*ssh, stdin_data: "")
        end
      Result.new(status.success?, out, err)
    end

    def run_streaming(ssh, input)
      err_buf = +""
      status = nil
      Open3.popen3(*ssh) do |stdin, stdout, stderr, wait|
        writer = Thread.new do
          if input
            File.open(input, "rb") { |f| IO.copy_stream(f, stdin) }
          end
          stdin.close
        rescue Errno::EPIPE
          nil
        end
        readers = [
          Thread.new { stdout.each_line { |l| @out.print "  │ #{l}" } },
          Thread.new { stderr.each_line { |l| err_buf << l; @out.print "  │ #{l}" } }
        ]
        writer.join
        readers.each(&:join)
        status = wait.value
      end
      Result.new(status.success?, "", err_buf)
    end
  end
end
