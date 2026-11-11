require "json"
require "time"
require "fileutils"

module Quickhost
  # Keeps connected sites up to date. A site is connected when it was deployed from a git URL
  # (or owner/repo): its container then carries the repo, branch, commit and deploy options.
  # One pass asks each repo which commit its branch is on (`git ls-remote`, no clone) and
  # redeploys the sites whose branch has moved. Meant to run from a timer on the server.
  class Sync
    # status: :current, :deployed, :would_deploy, :failed (this pass), :waiting (a commit that failed
    # before; nothing to do until the branch moves), :skipped
    Result = Struct.new(:name, :status, :detail)

    def self.default_state_path
      ENV["QUICKHOST_STATE"] || File.join(Dir.home, ".local", "state", "quickhost", "sync.json")
    end

    # resolver: (url, branch) -> remote commit sha. source_for: (url, branch) -> prepared Source.
    def initialize(config:, deployer:, out: $stdout, state_path: self.class.default_state_path,
                   resolver: Source.method(:remote_commit), source_for: ->(url, branch) { Source.new(url, branch: branch).prepare })
      @config = config
      @deployer = deployer
      @out = out
      @state_path = state_path
      @resolver = resolver
      @source_for = source_for
    end

    # Sites that sync watches, as label hashes.
    def connected
      @deployer.sites.select { |s| !s["quickhost.repo"].to_s.empty? }
    end

    # only: site names to limit the pass to. dry_run: say what would deploy, change nothing.
    def run(only: [], dry_run: false)
      with_lock do
        state = load_state
        heads = {}   # one lookup per repo+branch, however many sites share it
        results = connected.sort_by { |s| s[Site::LABEL] }.filter_map do |labels|
          name = labels[Site::LABEL]
          next if only.any? && !only.include?(name)
          next Result.new(name, :skipped, "in sync_skip") if Array(@config.sync_skip).map(&:to_s).include?(name)

          check(labels, state, heads, dry_run)
        end
        save_state(state) unless dry_run
        results
      end
    end

    private

    def check(labels, state, heads, dry_run)
      name = labels[Site::LABEL]
      url = labels["quickhost.repo"]
      branch = labels["quickhost.branch"].to_s.empty? ? nil : labels["quickhost.branch"]
      head = (heads[[url, branch]] ||= @resolver.call(url, branch))
      return Result.new(name, :current, short(head)) if head == labels["quickhost.commit"]

      # A commit that already failed to build is not tried again every minute: wait for the next one.
      failed = state.dig(name, "failed")
      return Result.new(name, :waiting, "#{short(head)} failed to deploy: #{state.dig(name, 'error')}") if failed == head
      return Result.new(name, :would_deploy, "#{short(labels['quickhost.commit'])} → #{short(head)}") if dry_run

      deploy(labels, url, branch, head)
      state.delete(name)
      Result.new(name, :deployed, "#{short(labels['quickhost.commit'])} → #{short(head)}")
    rescue Error => e
      # A lookup that fails (network, GitHub down) is retried next pass; a deploy that fails is remembered.
      state[name] = { "failed" => head, "error" => e.message.lines.first.to_s.strip, "at" => Time.now.utc.iso8601 } if head
      Result.new(name, :failed, e.message)
    end

    def deploy(labels, url, branch, head)
      options = JSON.parse(labels["quickhost.options"].to_s.empty? ? "{}" : labels["quickhost.options"])
      options["name"] = labels[Site::LABEL]
      source = @source_for.call(url, branch)
      begin
        @out.puts "→ #{labels[Site::LABEL]}: #{branch || 'default branch'} moved to #{short(head)}"
        site = Site.new(root: source.root, config: @config, options: options, fallback_name: source.repo_name)
        @deployer.deploy(site, source, synced: head)
      ensure
        source.cleanup
      end
    rescue JSON::ParserError
      raise Error, "Stored deploy options for #{labels[Site::LABEL]} are unreadable; redeploy it once by hand"
    end

    def short(sha) = sha.to_s.empty? ? "(none)" : sha.to_s[0, 7]

    def load_state
      File.exist?(@state_path) ? JSON.parse(File.read(@state_path)) : {}
    rescue JSON::ParserError
      {}
    end

    def save_state(state)
      FileUtils.mkdir_p(File.dirname(@state_path))
      File.write(@state_path, JSON.pretty_generate(state))
    end

    # One pass at a time: a pass still building when the next timer tick fires makes that tick a no-op.
    def with_lock
      FileUtils.mkdir_p(File.dirname(@state_path))
      File.open("#{@state_path}.lock", File::RDWR | File::CREAT) do |f|
        raise Error, "Another quickhost sync is still running" unless f.flock(File::LOCK_EX | File::LOCK_NB)

        yield
      end
    end
  end
end
