require "optparse"
require "fileutils"

module Quickhost
  class CLI
    USAGE = <<~TXT.freeze
      quickhost — GitHub-Pages-style hosting on your own server, via kamal-proxy

      Usage:
        quickhost deploy [PATH | GIT_URL | owner/repo] [options]
        quickhost list
        quickhost logs NAME [-f]
        quickhost rollback NAME [--to TAG]
        quickhost remove NAME [--yes]
        quickhost hub [--name NAME] [--out FILE] [--dry-run]
        quickhost sync [NAME...] [--dry-run] [-v]
        quickhost sync --install [--interval SECONDS]
        quickhost doctor
        quickhost init [--server user@host] [--base-domain example.com]

      Deploy options:
        -n, --name NAME        Site name (default: repo/folder name) → NAME.<base_domain>
        -d, --domain HOST      Serve on this exact hostname instead (e.g. blog.example.com)
        -b, --branch BRANCH    Branch, tag or commit to deploy (local repos too)
            --build CMD        Build command to run in a Node container
            --dir DIR          Folder to serve (or build output folder)
            --spa              Send unknown paths to index.html (React/Vue routers)
            --dry-run          Print the server commands without running them
        -v, --verbose          Stream the full Docker build log

      sync redeploys every connected site whose branch has a new commit. A site is connected when
      it was deployed from a git URL or owner/repo; `quickhost list` shows what each one follows.
      sync --install writes a systemd timer that runs it every minute on the server (server: local).

      hub builds a link page of every site kamal-proxy routes (quickhost sites and Kamal apps)
      and deploys it to <hub_name>.<base_domain> (default: sites). --out FILE only writes the page.
      Hide sites with `hub_hide:` in the config file.

      Per-repo defaults can live in .quickhost.yml (name, domain, build, dir, spa, node_image).
      Config: #{Config.default_path}
    TXT

    def self.start(argv, out: $stdout, err: $stderr)
      new(out: out, err: err).run(argv.dup)
    end

    def initialize(out:, err:)
      @out = out
      @err = err
    end

    def run(argv)
      command = argv.shift
      case command
      when "deploy"            then deploy(argv)
      when "list", "ls"        then list(argv)
      when "logs"              then logs(argv)
      when "rollback"          then rollback(argv)
      when "remove", "rm"      then remove(argv)
      when "hub"               then hub(argv)
      when "sync"              then sync(argv)
      when "doctor"            then doctor(argv)
      when "init"              then init(argv)
      when nil, "help", "-h", "--help" then @out.puts(USAGE); 0
      when "version", "-v", "--version" then @out.puts(VERSION); 0
      else
        @err.puts "Unknown command: #{command}\n\n#{USAGE}"
        1
      end
    rescue Error, OptionParser::ParseError => e
      @err.puts "✗ #{e.message}"
      1
    end

    private

    def deploy(argv)
      opts = {}
      dry_run = false
      verbose = false
      branch = nil
      OptionParser.new do |o|
        o.on("-n", "--name NAME") { |v| opts[:name] = v }
        o.on("-d", "--domain HOST") { |v| opts[:domain] = v }
        o.on("-b", "--branch BRANCH") { |v| branch = v }
        o.on("--build CMD") { |v| opts[:build] = v }
        o.on("--dir DIR") { |v| opts[:dir] = v }
        o.on("--spa") { opts[:spa] = true }
        o.on("--dry-run") { dry_run = true }
        o.on("-v", "--verbose") { verbose = true }
      end.parse!(argv)
      raise Error, "deploy takes one source, got: #{argv.join(' ')}" if argv.size > 1

      config = Config.load
      source = Source.new(argv.first, branch: branch)
      @out.puts "→ Fetching #{source.url}" if source.remote?
      source.prepare
      @out.puts "→ Using #{branch} (#{source.revision}) — committed files only" if source.exported_branch?
      site = Site.new(root: source.root, config: config, options: opts, fallback_name: source.repo_name)
      site.host # validate early
      site.mode

      @out.puts "⚠ Uncommitted changes will be deployed as they are on disk." if !source.remote? && source.dirty?
      @out.puts "(dry run — nothing will change on the server)" if dry_run

      remote = Remote.new(config.server, dry_run: dry_run, out: @out)
      deployer = Deployer.new(config: config, remote: remote, out: @out, verbose: verbose)
      deployer.preflight!
      deployer.deploy(site, source)
      @out.puts "\n✓ #{dry_run ? 'Would be live' : 'Live'} at #{config.tls ? 'https' : 'http'}://#{site.host}"
      @out.puts "  Connected: `quickhost sync` redeploys it when #{branch || 'the default branch'} gets a new commit." if source.remote? && !dry_run
      0
    ensure
      source&.cleanup
    end

    def list(_argv)
      config = Config.load
      rows = deployer(config).list.split("\n").map { |l| l.split("\t") }
      if rows.empty?
        @out.puts "No quickhost sites yet. Try: quickhost deploy ."
      else
        scheme = config.tls ? "https" : "http"
        widths = [rows.map { |r| r[0].to_s.size }.max, 4].max
        rows.sort.each do |name, host, image, status, repo, branch|
          url = "#{scheme}://#{host}"
          follows = repo.to_s.empty? ? "" : "  ← #{repo.sub(%r{\Ahttps://github\.com/}, '').sub(/\.git\z/, '')}@#{branch.to_s.empty? ? 'default' : branch}"
          @out.puts format("%-#{widths}s  %-#{[url.size, 40].max}s  %-23s  %s%s", name, url, image.to_s.split(":").last, status, follows)
        end
      end
      0
    end

    def logs(argv)
      follow = false
      OptionParser.new { |o| o.on("-f", "--follow") { follow = true } }.parse!(argv)
      name = argv.shift or raise Error, "Usage: quickhost logs NAME [-f]"
      deployer(Config.load).logs(name, follow: follow)
      0
    end

    def rollback(argv)
      to = nil
      OptionParser.new { |o| o.on("--to TAG") { |v| to = v } }.parse!(argv)
      name = argv.shift or raise Error, "Usage: quickhost rollback NAME [--to TAG]"
      container = deployer(Config.load).rollback(name, to: to)
      @out.puts "✓ Rolled back #{name} (#{container})"
      0
    end

    def remove(argv)
      yes = false
      OptionParser.new { |o| o.on("-y", "--yes") { yes = true } }.parse!(argv)
      name = argv.shift or raise Error, "Usage: quickhost remove NAME [--yes]"
      unless yes
        @out.print "Take #{name} offline and delete its containers and images? [y/N] "
        return 1 unless $stdin.gets.to_s.strip.downcase.start_with?("y")
      end
      deployer(Config.load).remove(name)
      @out.puts "✓ Removed #{name}"
      0
    end

    def hub(argv)
      name = nil
      out_file = nil
      dry_run = false
      OptionParser.new do |o|
        o.on("-n", "--name NAME") { |v| name = v }
        o.on("-o", "--out FILE") { |v| out_file = v }
        o.on("--dry-run") { dry_run = true }
      end.parse!(argv)
      config = Config.load
      remote = Remote.new(config.server, dry_run: dry_run, out: @out)
      writer = Deployer.new(config: config, remote: remote, out: @out)
      # Listing routes and checking sites are read-only, so they use a live connection even in a dry run.
      hub = Hub.new(config: config, deployer: writer, routes_from: deployer(config), name: name, out: @out)
      if out_file
        File.write(out_file, hub.html)
        @out.puts "✓ Wrote #{out_file} (#{hub.entries.size} sites)"
        return 0
      end

      @out.puts "(dry run — nothing will change on the server)" if dry_run
      hub.deploy
      @out.puts "\n✓ #{dry_run ? 'Would be live' : 'Live'} at #{hub.scheme}://#{hub.host}"
      0
    end

    def sync(argv)
      dry_run = false
      verbose = false
      install = false
      interval = 60
      OptionParser.new do |o|
        o.on("--dry-run") { dry_run = true }
        o.on("-v", "--verbose") { verbose = true }
        o.on("--install") { install = true }
        o.on("--interval SECONDS", Integer) { |v| interval = v }
      end.parse!(argv)
      return install_timer(interval) if install

      config = Config.load
      results = Sync.new(config: config, deployer: deployer(config), out: @out).run(only: argv.map { |n| Site.sanitize(n) }, dry_run: dry_run)
      @out.puts "No connected sites. Deploy one from its repo: quickhost deploy owner/repo --branch deploy" if results.empty? && verbose
      results.each do |r|
        case r.status
        when :deployed     then @out.puts "✓ #{r.name} deployed (#{r.detail})"
        when :would_deploy then @out.puts "#{r.name} would deploy (#{r.detail})"
        when :failed       then @err.puts "✗ #{r.name}: #{r.detail}"
        else @out.puts "· #{r.name} #{r.status} (#{r.detail})" if verbose || dry_run
        end
      end
      results.any? { |r| r.status == :failed } ? 1 : 0
    end

    # Writes a systemd user timer that runs `quickhost sync` on this machine, and says how to start it.
    def install_timer(interval)
      raise Error, "--interval must be at least 30 seconds" if interval < 30

      require "rbconfig"
      dir = File.join(ENV["XDG_CONFIG_HOME"] || File.join(Dir.home, ".config"), "systemd", "user")
      bin = File.expand_path("../../bin/quickhost", __dir__)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "quickhost-sync.service"), <<~UNIT)
        [Unit]
        Description=quickhost: redeploy sites whose branch has a new commit
        After=network-online.target docker.service

        [Service]
        Type=oneshot
        Environment=PATH=#{ENV['PATH']}
        ExecStart=#{RbConfig.ruby} #{bin} sync
      UNIT
      File.write(File.join(dir, "quickhost-sync.timer"), <<~UNIT)
        [Unit]
        Description=Run quickhost sync every #{interval} seconds

        [Timer]
        OnBootSec=#{interval}
        OnUnitActiveSec=#{interval}
        AccuracySec=1s

        [Install]
        WantedBy=timers.target
      UNIT
      @out.puts <<~TXT
        ✓ Wrote #{dir}/quickhost-sync.service and quickhost-sync.timer

        Start it:
          systemctl --user daemon-reload
          systemctl --user enable --now quickhost-sync.timer
          sudo loginctl enable-linger #{ENV['USER'] || '$USER'}     # keeps it running when you're logged out

        Watch it:
          journalctl --user -u quickhost-sync -f
          quickhost sync -v
      TXT
      0
    end

    def doctor(_argv)
      config = Config.load
      @out.puts "Server: #{config.server}   Base domain: #{config.base_domain}"
      d = deployer(config)
      checks = d.doctor
      checks.each { |label, ok| @out.puts "#{ok ? '✓' : '✗'} #{label}" }
      dns_check(config)
      if checks.all?(&:last)
        @out.puts "\nkamal-proxy routes:\n#{d.proxy_list}"
        0
      else
        1
      end
    end

    def init(argv)
      config = Config.load
      OptionParser.new do |o|
        o.on("--server SERVER") { |v| config.values["server"] = v }
        o.on("--base-domain DOMAIN") { |v| config.values["base_domain"] = v }
        o.on("--network NAME") { |v| config.values["network"] = v }
        o.on("--proxy-container NAME") { |v| config.values["proxy_container"] = v }
      end.parse!(argv)
      config.write!
      @out.puts "✓ Wrote #{config.path}"
      @out.puts File.read(config.path)
      0
    end

    def dns_check(config)
      require "resolv"
      probe = "qh-dns-check-#{rand(10_000)}.#{config.base_domain}"
      addr = begin
        Resolv.getaddress(probe)
      rescue Resolv::ResolvError
        nil
      end
      if addr
        @out.puts "✓ wildcard DNS *.#{config.base_domain} → #{addr}"
      else
        @out.puts "✗ wildcard DNS: #{probe} doesn't resolve. Add an A record for * pointing at your home IP " \
                  "(or one record per site)."
      end
    end

    def deployer(config)
      Deployer.new(config: config, remote: Remote.new(config.server, out: @out), out: @out)
    end
  end
end
