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

        @repo_name = git_toplevel_name || File.basename(File.expand_path(@arg))
        if @branch
          export_branch
        else
          @root = File.expand_path(@arg)
        end
      end
      self
    end

    # True when a local repo's branch was exported, rather than deploying the folder as it is on disk.
    def exported_branch? = !remote? && !@branch.nil?

    # Short commit sha, if the folder is a git checkout.
    def revision
      return @revision if @revision

      out, _err, status = Open3.capture3("git", "-C", root, "rev-parse", "--short", "HEAD")
      status.success? ? out.strip : nil
    end

    def dirty?
      return false if exported_branch?

      out, _err, status = Open3.capture3("git", "-C", root, "status", "--porcelain")
      status.success? && !out.strip.empty?
    end

    def cleanup
      FileUtils.rm_rf(@tmp) if @tmp
    end

    # Where auto-updates would pull from: { repo:, branch: }, or nil when there's no git remote
    # to follow (a plain folder, a subfolder of a repo, or a repo without an origin).
    # branch nil means the repo's default branch.
    def tracking
      return { repo: self.class.public_url(url), branch: @branch } if remote?
      return unless git_toplevel_name

      origin, _err, status = git("remote", "get-url", "origin")
      return unless status.success? && !origin.strip.empty?

      branch = @branch&.delete_prefix("origin/")
      branch ||= begin
        head, _err, ok = git("symbolic-ref", "--quiet", "--short", "HEAD") # fails on a detached HEAD
        ok.success? ? head.strip : nil
      end
      branch && { repo: self.class.public_url(origin.strip), branch: branch }
    end

    # The https form of a git URL, without any embedded login. The server has no ssh keys for
    # GitHub, and tokens don't belong in container labels.
    def self.public_url(url)
      url = url.sub(%r{\A(?:ssh://)?git@([^:/]+)[:/](.+)\z}, 'https://\1/\2')
      url.sub(%r{\A(https?://)[^/@]+@}, '\1')
    end

    private

    def git(*args)
      Open3.capture3("git", "-C", @arg, *args, binmode: true)
    end

    # Copies the committed contents of @branch into a temp folder with `git archive`,
    # leaving the user's checkout and working tree untouched. Accepts any ref git does
    # (local branch, origin/branch, tag, commit). Deploying a subfolder exports that
    # subfolder from the branch.
    def export_branch
      _out, _err, status = git("rev-parse", "--git-dir")
      raise Error, "--branch needs #{@arg} to be a git repo" unless status.success?

      sha, _err, status = git("rev-parse", "--verify", "--quiet", "--short", "#{@branch}^{commit}")
      # Branches you haven't checked out locally usually still exist as origin/<branch>.
      sha, _err, status = git("rev-parse", "--verify", "--quiet", "--short", "origin/#{@branch}^{commit}") unless status.success?
      unless status.success?
        raise Error, "No branch or commit named '#{@branch}' in #{File.expand_path(@arg)}. " \
                     "For a branch that only exists on GitHub, run `git fetch` first or use origin/#{@branch}."
      end
      @revision = sha.strip

      prefix, _err, _status = git("rev-parse", "--show-prefix")
      prefix = prefix.strip
      treeish = prefix.empty? ? @revision : "#{@revision}:#{prefix.chomp('/')}"

      @tmp = Dir.mktmpdir("quickhost-src-")
      @root = File.join(@tmp, "repo")
      FileUtils.mkdir_p(@root)
      # Run from the repo root: from a subfolder, git archive would also filter by that path.
      top, _err, _status = git("rev-parse", "--show-toplevel")
      archive, err, status = Open3.capture3("git", "-C", top.strip, "archive", "--format=tar", treeish, binmode: true)
      raise Error, "git archive failed for #{@branch}:\n#{err.strip}" unless status.success?

      _out, err, status = Open3.capture3("tar", "-x", "-C", @root, stdin_data: archive, binmode: true)
      raise Error, "Couldn't unpack #{@branch}:\n#{err.strip}" unless status.success?
    end

    def git_toplevel_name
      out, _err, status = Open3.capture3("git", "-C", @arg, "rev-parse", "--show-toplevel")
      return unless status.success?

      top = out.strip
      # Only use the repo name when deploying the repo root itself, not a subfolder.
      File.expand_path(top) == File.expand_path(@arg) ? File.basename(top) : nil
    end
  end
end
