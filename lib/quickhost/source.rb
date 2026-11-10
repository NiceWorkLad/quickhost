require "open3"
require "tmpdir"
require "fileutils"

module Quickhost
  # Turns the deploy argument into a local folder: an existing path, a git URL,
  # or GitHub shorthand like "NiceWorkLad/Ball-Game".
  class Source
    GIT_URL = %r{\A(https?://|ssh://|git@|file://)}
    SHORTHAND = %r{\A[\w.-]+/[\w.-]+\z}

    attr_reader :root, :repo_name

    def initialize(arg, branch: nil)
      @arg = arg || "."
      @branch = branch
    end

    def remote?
      return false if File.directory?(@arg)

      @arg.match?(GIT_URL) || @arg.match?(SHORTHAND)
    end

    def url
      @arg.match?(SHORTHAND) && !@arg.match?(GIT_URL) ? "https://github.com/#{@arg}.git" : @arg
    end

    def prepare
      if remote?
        @tmp = Dir.mktmpdir("quickhost-src-")
        @root = File.join(@tmp, "repo")
        cmd = ["git", "clone", "--depth", "1"]
        cmd += ["--branch", @branch] if @branch
        cmd += [url, @root]
        _out, err, status = Open3.capture3(*cmd)
        raise Error, "git clone failed for #{url}:\n#{err.strip}" unless status.success?

        @repo_name = File.basename(url.sub(%r{/+\z}, ""), ".git")
      else
        raise Error, "#{@arg} is not a folder" unless File.directory?(@arg)
        raise Error, "--branch only works with git URLs; check out the branch locally instead" if @branch

        @root = File.expand_path(@arg)
        @repo_name = git_toplevel_name || File.basename(@root)
      end
      self
    end

    # Short commit sha, if the folder is a git checkout.
    def revision
      out, _err, status = Open3.capture3("git", "-C", root, "rev-parse", "--short", "HEAD")
      status.success? ? out.strip : nil
    end

    def dirty?
      out, _err, status = Open3.capture3("git", "-C", root, "status", "--porcelain")
      status.success? && !out.strip.empty?
    end

    def cleanup
      FileUtils.rm_rf(@tmp) if @tmp
    end

    private

    def git_toplevel_name
      out, _err, status = Open3.capture3("git", "-C", @arg, "rev-parse", "--show-toplevel")
      return unless status.success?

      top = out.strip
      # Only use the repo name when deploying the repo root itself, not a subfolder.
      File.expand_path(top) == File.expand_path(@arg) ? File.basename(top) : nil
    end
  end
end
