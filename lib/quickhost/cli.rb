require "json"
require "optparse"

module Quickhost
  class CLI
    USAGE = <<~TXT.freeze
      quickhost — GitHub-Pages-style hosting on your own server, via kamal-proxy

      Usage:
        quickhost deploy [PATH | GIT_URL | owner/repo] [options]
        quickhost list [--json]                 Every site: URL, version, age, state, access, auto-updates
        quickhost status NAME [--json]          Everything about one site, plus a live check that it answers
        quickhost open NAME                     Open the site in your browser
        quickhost logs NAME [-f] [--tail N]
        quickhost rollback NAME [--to TAG]
        quickhost remove NAME [--yes]

        quickhost private NAME [--password PW] [--user USER]   Put a site behind a password
        quickhost public NAME                                  Open it up again

        quickhost auto                          Is the updater running, and which sites follow their repo?
        quickhost auto on|off NAME              Turn auto-updates on or off for a site
        quickhost auto start [--interval 5m]    Install / restart the updater on the server
        quickhost auto stop | logs [-f]
        quickhost update [NAME...] [--force]    Check for new commits now and redeploy what changed

        quickhost hub [--name NAME] [--out FILE] [--dry-run]
        quickhost doctor
        quickhost init [--server user@host] [--base-domain example.com]

      Deploy options:
        -n, --name NAME        Site name (default: repo/folder name) → NAME.<base_domain>
        -d, --domain HOST      Serve on this exact hostname instead (e.g. blog.example.com)
        -b, --branch BRANCH    Branch, tag or commit to deploy (local repos too)
            --build CMD        Build command to run in a Node container
            --dir DIR          Folder to serve (or build output folder)
            --spa              Send unknown paths to index.html (React/Vue routers)
            --private          Ask visitors for a password (--password PW, --user USER; or one is generated)
            --public           Stop asking for a password
            --auto, --no-auto  Redeploy by itself when the branch gets new commits (needs `auto start` once)
            --dry-run          Print the server commands without running them
        -v, --verbose          Stream the full Docker build log

      Private and auto-update settings stick: later deploys keep them unless you pass the opposite flag.

      hub builds a link page of every site kamal-proxy routes (quickhost sites and Kamal apps)
      and deploys it to <hub_name>.<base_domain> (default: sites). --out FILE only writes the page.
      Hide sites with `hub_hide:` in the config file.

      Per-repo defaults can live in .quickhost.yml (name, domain, build, dir, spa, node_image, private, auto).
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
      when "status", "info"    then status(argv)
      when "open"              then open_site(argv)
      when "private"           then set_private(argv)
      when "public"            then set_public(argv)
      when "auto"              then auto(argv)
      when "update"            then update(argv)
      when "logs"              then logs(argv)
      when "rollback"          then rollback(argv)
      when "remove", "rm"      then remove(argv)
      when "hub"               then hub(argv)
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
      user = nil
      password = nil
      OptionParser.new do |o|
        o.on("-n", "--name NAME") { |v| opts[:name] = v }
        o.on("-d", "--domain HOST") { |v| opts[:domain] = v }
        o.on("-b", "--branch BRANCH") { |v| branch = v }
        o.on("--build CMD") { |v| opts[:build] = v }
        o.on("--dir DIR") { |v| opts[:dir] = v }
        o.on("--spa") { opts[:spa] = true }
        o.on("--private") { opts[:private] = true }
        o.on("--public") { opts[:private] = false }
        o.on("--password PW") { |v| password = v }
        o.on("--user USER") { |v| user = v }
        o.on("--[no-]auto") { |v| opts[:auto] = v }
        o.on("--dry-run") { dry_run = true }
        o.on("-v", "--verbose") { verbose = true }
      end.parse!(argv)
      raise Error, "--public can't be combined with --password or --user" if opts[:private] == false && (password || user)
      opts[:private] = true if password || user
      raise Error, "deploy takes one source, got: #{argv.join(' ')}" if argv.size > 1

      config = Config.load
      source = Source.new(argv.first, branch: branch)
      @out.puts "→ Fetching #{source.url}" if source.remote?
      source.prepare
      @out.puts "→ Using #{branch} (#{source.revision}) — committed files only" if source.exported_branch?
      site = Site.new(root: source.root, config: config, options: opts, fallback_name: source.repo_name)
      site.host # validate early
      site.mode

      dirty = !source.remote? && source.dirty?
      @out.puts "⚠ Uncommitted changes will be deployed as they are on disk." if dirty
      track = source.tracking
      if site.auto && track && !source.remote?
        @out.puts "⚠ Auto-updates follow what is pushed to #{track[:repo]} (#{track[:branch]}); " \
                  "anything not pushed there is replaced at the next check."
      end
      password ||= ENV["QUICKHOST_PASSWORD"] if site.private
      @out.puts "(dry run — nothing will change on the server)" if dry_run

      remote = Remote.new(config.server, dry_run: dry_run, out: @out)
      deployer = Deployer.new(config: config, remote: remote, out: @out, verbose: verbose)
      deployer.preflight!
      deployer.deploy(site, source, track: track, user: user, password: password)
      @out.puts "\n✓ #{dry_run ? 'Would be live' : 'Live'} at #{config.tls ? 'https' : 'http'}://#{site.host}"
      report_settings(deployer, site.name, config) unless dry_run
      0
    ensure
      source&.cleanup
    end

    def list(argv)
      json = false
      OptionParser.new { |o| o.on("--json") { json = true } }.parse!(argv)
      config = Config.load
      scheme = config.tls ? "https" : "http"
      infos = deployer(config).sites
      if json
        @out.puts JSON.pretty_generate(infos.map { |i| i.to_h(scheme) })
      elsif infos.empty?
        @out.puts "No quickhost sites yet. Try: quickhost deploy ."
      else
        rows = infos.map do |i|
          [i.name, "#{scheme}://#{i.host}", i.tag.to_s, age(i.deployed_at), i.state,
           i.meta.private? ? "private" : "public", auto_word(i.meta)]
        end
        table(%w[NAME URL VERSION DEPLOYED STATE ACCESS AUTO], rows)
        following = infos.count { |i| i.meta.auto? }
        if following.positive? && !updater(config).status.running?
          @out.puts "\n⚠ Auto-updates are on for #{following} #{following == 1 ? 'site' : 'sites'} but the updater " \
                    "isn't running. Start it with: quickhost auto start"
        end
      end
      0
    end

    def status(argv)
      json = false
      OptionParser.new { |o| o.on("--json") { json = true } }.parse!(argv)
      name = argv.shift or raise Error, "Usage: quickhost status NAME [--json]"
      config = Config.load
      d = deployer(config)
      info = d.site_info(name) or raise Error, "No site named #{Site.sanitize(name)}. See: quickhost list"
      meta = info.meta
      scheme = config.tls ? "https" : "http"
      url = "#{scheme}://#{info.host}"
      versions = d.versions(info.name)
      route = Hub.parse_routes(d.proxy_list).find { |r| r[:service] == "#{Site::SERVICE_PREFIX}#{info.name}" }
      code, _body = Probe.get("#{url}/")
      up = meta.auto? ? updater(config).status : nil

      if json
        @out.puts JSON.pretty_generate(info.to_h(scheme).merge(
          responds: code, route: route && route[:state], versions: versions, updater_running: up&.running?
        ))
        return 0
      end

      answer =
        if meta.private? && code == 401 then "401 — asks for a password, as it should"
        elsif meta.private? && code.is_a?(Integer) && code < 400 then "#{code} — ✗ answered WITHOUT asking for a password"
        elsif code.is_a?(Integer) then "#{code}#{code < 400 ? ' OK' : ''}"
        else "✗ no answer (#{code})"
        end
      deployed = info.deployed_at
      auto_line =
        if !meta.auto? then meta.repo ? "off" : "off (no git source recorded; redeploy from a repo to use it)"
        elsif up.running? then "on — updater checks every #{Updater.format_interval(up.interval)}"
        else "on, but the updater isn't running — start it with: quickhost auto start"
        end
      lines = [
        ["URL", url],
        ["State", "#{info.state} (#{info.container})"],
        ["Responds", answer],
        ["Version", "#{info.tag}#{deployed ? " — deployed #{deployed.strftime('%-d %b %Y %H:%M')} UTC, #{age(deployed)}" : ''}"],
        ["Source", meta.repo ? "#{meta.source_label}#{meta.revision ? " @ #{meta.revision}" : ''}" : "local folder#{meta.revision ? " @ #{meta.revision}" : ''}"],
        ["Access", meta.private? ? "private (user: #{meta.user})" : "public"],
        ["Auto-update", auto_line],
        ["Route", route ? "#{route[:service]} → #{route[:state]}" : "✗ not in kamal-proxy's routes"],
        ["Versions", versions.map { |t| t == info.tag ? "#{t}  ← live" : t }.join("\n" + " " * 15)]
      ]
      lines << ["Build flags", meta.options.map { |k, v| "#{k}=#{v}" }.join("  ")] unless meta.options.empty?
      @out.puts info.name
      lines.each { |label, value| @out.puts "  #{label.ljust(11)}  #{value}" }
      0
    end

    def open_site(argv)
      name = argv.shift or raise Error, "Usage: quickhost open NAME"
      config = Config.load
      info = deployer(config).site_info(name) or raise Error, "No site named #{Site.sanitize(name)}. See: quickhost list"
      url = "#{config.tls ? 'https' : 'http'}://#{info.host}"
      opener = [%w[wslview], %w[explorer.exe], %w[open], %w[xdg-open]].find do |cmd|
        next false if cmd == %w[explorer.exe] && !File.exist?("/proc/sys/fs/binfmt_misc/WSLInterop")

        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, cmd.first)) }
      end
      @out.puts url
      system(*opener, url, out: File::NULL, err: File::NULL) if opener
      0
    end

    def set_private(argv)
      user = nil
      password = ENV["QUICKHOST_PASSWORD"]
      OptionParser.new do |o|
        o.on("--password PW") { |v| password = v }
        o.on("--user USER") { |v| user = v }
      end.parse!(argv)
      name = argv.shift or raise Error, "Usage: quickhost private NAME [--password PW] [--user USER]"
      config = Config.load
      d = deployer(config)
      d.reconfigure(name, private: true, user: user, password: password)
      @out.puts "\n✓ #{Site.sanitize(name)} is now private"
      report_settings(d, name, config)
      0
    end

    def set_public(argv)
      name = argv.shift or raise Error, "Usage: quickhost public NAME"
      d = deployer(Config.load)
      info = d.site_info(name) or raise Error, "No site named #{Site.sanitize(name)}. See: quickhost list"
      unless info.meta.private?
        @out.puts "#{info.name} is already public."
        return 0
      end
      d.reconfigure(name, private: false)
      @out.puts "\n✓ #{info.name} is now public — anyone with the link can see it"
      0
    end

    def auto(argv)
      sub = argv.shift
      config = Config.load
      service = updater(config)
      case sub
      when nil, "status" then auto_status(config, service)
      when "on", "off"
        name = argv.shift or raise Error, "Usage: quickhost auto #{sub} NAME"
        d = deployer(config)
        info = d.site_info(name) or raise Error, "No site named #{Site.sanitize(name)}. See: quickhost list"
        if info.meta.auto? == (sub == "on")
          @out.puts "Auto-updates are already #{sub} for #{info.name}."
        else
          d.reconfigure(name, auto: sub == "on")
          @out.puts "\n✓ Auto-updates #{sub} for #{info.name}"
        end
        if sub == "on"
          @out.puts "  Following #{info.meta.source_label}"
          updater_hint(service)
        end
      when "start"
        interval = config.auto_interval
        OptionParser.new { |o| o.on("--interval TIME") { |v| interval = Updater.parse_interval(v) } }.parse!(argv)
        service.start(interval: interval)
        @out.puts "\n✓ Updater running on #{config.server}: checks every #{Updater.format_interval(interval)} " \
                  "for sites with auto-updates on"
      when "stop"
        service.stop
        @out.puts "✓ Updater stopped. Sites stay as they are; none will update by itself."
      when "logs"
        follow = false
        tail = 50
        OptionParser.new do |o|
          o.on("-f", "--follow") { follow = true }
          o.on("--tail N", Integer) { |v| tail = v }
        end.parse!(argv)
        raise Error, "The updater isn't installed. Start it with: quickhost auto start" unless service.status.installed?

        service.logs(tail: tail, follow: follow)
      else
        raise Error, "Unknown: quickhost auto #{sub}. Use: auto [status] | on NAME | off NAME | start | stop | logs"
      end
      0
    end

    def auto_status(config, service)
      st = service.status
      if st.running?
        stale = st.version == VERSION ? "" : " — built from quickhost #{st.version}; run `quickhost auto start` to bring it to #{VERSION}"
        @out.puts "Updater: ON — running on #{config.server}, checks every #{Updater.format_interval(st.interval)}#{stale}"
        service.recent(3).each { |line| @out.puts "  #{line}" }
      elsif st.installed?
        @out.puts "Updater: OFF — installed on #{config.server} but #{st.state}. Restart it with: quickhost auto start"
      else
        @out.puts "Updater: OFF — not installed on #{config.server}. Start it with: quickhost auto start"
      end

      infos = deployer(config).sites
      @out.puts
      if infos.empty?
        @out.puts "No quickhost sites yet."
      else
        rows = infos.map do |i|
          source = i.meta.repo ? "#{i.meta.source_label}#{i.meta.revision ? " @ #{i.meta.revision}" : ''}" : "no git source recorded"
          [i.name, auto_word(i.meta), source]
        end
        table(%w[SITE AUTO FOLLOWS], rows)
        if infos.none? { |i| i.meta.auto? }
          @out.puts "\nNo site has auto-updates on. Turn it on with: quickhost auto on NAME"
        end
      end
      0
    end

    def update(argv)
      force = false
      watch = nil
      OptionParser.new do |o|
        o.on("--force") { force = true }
        o.on("--all") { nil }
        o.on("--watch TIME") { |v| watch = Updater.parse_interval(v) }
      end.parse!(argv)
      config = Config.load
      runner = Updater.new(config: config, deployer: deployer(config), out: @out)
      if watch
        trap("TERM") { exit 0 }
        runner.watch(watch)
      end
      outcomes = runner.run(names: argv.empty? ? nil : argv, force: force)
      @out.puts "No site has auto-updates on. Turn it on with: quickhost auto on NAME" if outcomes.empty?
      outcomes.any? { |o| o.result == :failed } ? 1 : 0
    end

    def logs(argv)
      follow = false
      tail = 100
      OptionParser.new do |o|
        o.on("-f", "--follow") { follow = true }
        o.on("--tail N", Integer) { |v| tail = v }
      end.parse!(argv)
      name = argv.shift or raise Error, "Usage: quickhost logs NAME [-f] [--tail N]"
      deployer(Config.load).logs(name, follow: follow, tail: tail)
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

    # What a deploy or settings change left the site with: the login if one was just set, and
    # whether it follows its repo.
    def report_settings(deployer, name, config)
      meta = deployer.meta or return
      if deployer.credentials
        user, password, generated = deployer.credentials
        @out.puts "  Private — sign in with  user: #{user}  password: #{password}"
        if generated
          @out.puts "  This generated password is shown only now. `quickhost private #{Site.sanitize(name)}` sets a new one."
        end
      elsif meta.private?
        @out.puts "  Private — same login as before (user: #{meta.user})"
      end
      return unless meta.auto?

      @out.puts "  Auto-updates on — following #{meta.source_label}"
      updater_hint(updater(config))
    end

    def updater_hint(service)
      return if service.status.running?

      @out.puts "  ⚠ The updater isn't running yet, so nothing will update by itself. Start it with: quickhost auto start"
    end

    def auto_word(meta)
      return "on" if meta.auto?

      meta.repo ? "off" : "-"
    end

    def age(time)
      return "-" unless time

      seconds = (Time.now - time).to_i
      if seconds < 90 then "just now"
      elsif seconds < 5400 then "#{(seconds / 60.0).round}m ago"
      elsif seconds < 129_600 then "#{(seconds / 3600.0).round}h ago"
      else "#{(seconds / 86_400.0).round}d ago"
      end
    end

    def table(header, rows)
      widths = header.each_index.map { |i| ([header[i]] + rows.map { |r| r[i].to_s }).map(&:size).max }
      ([header] + rows).each do |row|
        @out.puts row.each_with_index.map { |cell, i| cell.to_s.ljust(widths[i]) }.join("  ").rstrip
      end
    end

    def updater(config)
      UpdaterService.new(config: config, remote: Remote.new(config.server, out: @out), out: @out)
    end

    def deployer(config)
      Deployer.new(config: config, remote: Remote.new(config.server, out: @out), out: @out)
    end
  end
end
