require "open3"
require "tmpdir"
require "fileutils"

module Quickhost
  # Redeploys sites whose git branch has moved on. `quickhost update` runs it once from wherever
  # you are; the updater container on the server (see UpdaterService) runs it on a timer.
  class Updater
    Outcome = Struct.new(:name, :result, :detail) # result: :current, :updated, :failed, :skipped

    def initialize(config:, deployer:, out: $stdout, resolver: nil)
      @config = config
      @deployer = deployer
      @out = out
      @resolver = resolver || method(:remote_sha)
      @failed = {} # site name => commit that failed to deploy; skipped until a new commit arrives
    end

    # "90" / "90s" / "5m" / "2h" → seconds.
    def self.parse_interval(text)
      match = text.to_s.strip.match(/\A(\d+)\s*([smh]?)\z/i) or raise Error, "Can't read interval #{text.inspect}; use e.g. 90s, 5m or 1h"
      seconds = match[1].to_i * { "" => 1, "s" => 1, "m" => 60, "h" => 3600 }[match[2].downcase]
      raise Error, "Interval must be at least 30 seconds" if seconds < 30

      seconds
    end

    def self.format_interval(seconds)
      seconds = seconds.to_i
      return "#{seconds / 3600}h" if (seconds % 3600).zero? && seconds.positive?
      return "#{seconds / 60}m" if (seconds % 60).zero? && seconds.positive?

      "#{seconds}s"
    end

    # names: the sites to check; nil means every site with auto-updates on.
    # force: redeploy even when the live commit is already the newest.
    def run(names: nil, force: false, remember_failures: false)
      all = @deployer.sites
      targets =
        if names
          names.map do |n|
            all.find { |s| s.name == Site.sanitize(n) } or raise Error, "No site named #{n}. See: quickhost list"
          end
        else
          all.select { |s| s.meta.auto? }
        end
      targets.map { |info| update(info, force: force, remember_failures: remember_failures) }
    end

    # Checks forever. Used by the updater container.
    def watch(interval)
      @out.puts "#{stamp} quickhost #{VERSION} updater: checking every #{self.class.format_interval(interval)}"
      loop do
        begin
          outcomes = run(remember_failures: true)
          tally = outcomes.group_by(&:result).map { |result, list| "#{list.size} #{result}" }.join(", ")
          @out.puts "#{stamp} checked #{outcomes.size} #{outcomes.size == 1 ? 'site' : 'sites'}#{tally.empty? ? '' : ": #{tally}"}"
        rescue Error => e
          @out.puts "#{stamp} check failed: #{e.message}"
        end
        sleep interval
      end
    end

    private

    def update(info, force:, remember_failures:)
      meta = info.meta
      raise Error, "#{info.name} has no git source recorded; redeploy it from a repo first" unless meta.repo

      sha = @resolver.call(meta.repo, meta.branch)
      if !force && meta.revision && sha.start_with?(meta.revision)
        @out.puts "✓ #{info.name} is up to date (#{meta.revision})" unless remember_failures
        return Outcome.new(info.name, :current, meta.revision)
      end
      return Outcome.new(info.name, :skipped, "#{sha[0, 7]} failed before") if remember_failures && @failed[info.name] == sha

      @out.puts "→ #{info.name}: #{meta.revision || 'unknown'} → #{sha[0, 7]} from #{meta.source_label}"
      redeploy(info)
      @failed.delete(info.name)
      @out.puts "✓ #{info.name} updated to #{sha[0, 7]}"
      Outcome.new(info.name, :updated, sha[0, 7])
    rescue Error => e
      @failed[info.name] = sha if sha
      @out.puts "✗ #{info.name}: #{e.message}"
      Outcome.new(info.name, :failed, e.message)
    end

    def redeploy(info)
      meta = info.meta
      source = Source.new(meta.repo, branch: meta.branch).prepare
      # Pin the name and host so a renamed repo or edited .quickhost.yml can't move the site.
      options = meta.options.merge("name" => info.name, "domain" => meta.host)
      site = Site.new(root: source.root, config: @config, options: options, fallback_name: info.name)
      site.mode
      @deployer.deploy(site, source, track: { repo: meta.repo, branch: meta.branch })
    ensure
      source&.cleanup
    end

    # The commit a branch points at right now, without cloning.
    def remote_sha(repo, branch)
      ref = branch || "HEAD"
      out, err, status = Open3.capture3({ "GIT_TERMINAL_PROMPT" => "0" }, "git", "ls-remote", repo, ref)
      raise Error, "Couldn't reach #{repo}: #{err.strip.lines.last.to_s.strip}" unless status.success?

      refs = out.lines.map(&:split)
      hit = refs.find { |_, name| name == "refs/heads/#{ref}" } || refs.find { |_, name| name == ref } || refs.first
      raise Error, "No branch '#{ref}' in #{repo}" unless hit

      hit.first
    end

    def stamp = Time.now.utc.strftime("[%Y-%m-%d %H:%M:%SZ]")
  end

  # The updater on the server: a small container holding a copy of quickhost, with access to the
  # server's Docker, that runs `quickhost update --watch`. It only touches sites with auto-updates on.
  class UpdaterService
    CONTAINER = "qh-updater".freeze
    IMAGE = "quickhost/updater".freeze
    ROOT = File.expand_path("../..", __dir__)
    PASSED_ON = %w[base_domain network proxy_container tls keep_images].freeze

    Status = Struct.new(:state, :version, :interval, :started, keyword_init: true) do
      def installed? = !state.nil?
      def running? = state == "running"
    end

    DOCKERFILE = <<~DOCKER.freeze
      FROM ruby:3.3-alpine
      RUN apk add --no-cache git tar docker-cli docker-cli-buildx
      COPY bin/ /opt/quickhost/bin/
      COPY lib/ /opt/quickhost/lib/
      ENV QUICKHOST_SERVER=local
      ENTRYPOINT ["ruby", "/opt/quickhost/bin/quickhost"]
    DOCKER

    def initialize(config:, remote:, out: $stdout)
      @config = config
      @remote = remote
      @out = out
    end

    def status
      res = docker("inspect", "-f",
                   '{{.State.Status}}|{{index .Config.Labels "quickhost.updater"}}|' \
                   '{{index .Config.Labels "quickhost.interval"}}|{{.State.StartedAt}}',
                   CONTAINER, allow_fail: true)
      return Status.new unless res.ok? && !res.out.strip.empty?

      state, version, interval, started = res.out.strip.split("|")
      Status.new(state: state, version: version, interval: interval.to_i, started: started)
    end

    # Builds the updater image from this copy of quickhost and (re)starts it.
    def start(interval: @config.auto_interval)
      Dir.mktmpdir("quickhost-updater-") do |dir|
        %w[bin lib].each { |d| FileUtils.cp_r(File.join(ROOT, d), dir) }
        File.write(File.join(dir, "Dockerfile"), DOCKERFILE)
        tarball = File.join(dir, "context.tgz")
        _out, err, ok = Open3.capture3("tar", "-C", dir, "-czf", tarball, "Dockerfile", "bin", "lib")
        raise Error, "Could not package the updater: #{err}" unless ok.success?

        @out.puts "→ Building #{IMAGE}:#{VERSION} on #{@config.server}"
        build = docker("build", "-t", "#{IMAGE}:#{VERSION}", "-", input: tarball, allow_fail: true)
        unless build.ok?
          tail = (build.out + build.err).lines.last(15).map { |l| "  │ #{l}" }.join
          raise Error, "Couldn't build the updater on #{@config.server}.\n#{tail}"
        end
      end

      @out.puts "→ Starting #{CONTAINER} (checks every #{Updater.format_interval(interval)})"
      docker("rm", "-f", CONTAINER, allow_fail: true)
      env = PASSED_ON.flat_map { |key| ["-e", "#{Config::ENV_KEYS[key]}=#{@config.public_send(key)}"] }
      docker("run", "-d", "--name", CONTAINER, "--restart", "unless-stopped",
             "--label", "quickhost.updater=#{VERSION}", "--label", "quickhost.interval=#{interval}",
             "-v", "/var/run/docker.sock:/var/run/docker.sock", *env,
             "#{IMAGE}:#{VERSION}", "update", "--watch", interval.to_s)
    end

    def stop
      docker("rm", "-f", CONTAINER, allow_fail: true).ok?
    end

    def logs(tail: 50, follow: false)
      args = ["logs", "--tail", tail.to_s]
      args << "-f" if follow
      docker(*args, CONTAINER, stream: true)
    end

    def recent(lines = 3)
      res = docker("logs", "--tail", lines.to_s, CONTAINER, allow_fail: true)
      (res.out + res.err).lines.map(&:rstrip).reject(&:empty?).last(lines)
    end

    private

    def docker(*args, **opts) = @remote.run("docker", *args, **opts)
  end
end
