require "json"
require "open3"
require "tmpdir"

module Quickhost
  # Talks to Docker and kamal-proxy on the server.
  class Deployer
    def initialize(config:, remote:, out: $stdout, verbose: false)
      @config = config
      @remote = remote
      @out = out
      @verbose = verbose
    end

    # [user, password] when the last deploy or change generated or set a new password; else nil.
    attr_reader :credentials
    # Settings (Meta) the last deploy or change left the site with.
    attr_reader :meta

    def preflight!
      step "Checking #{@config.server}"
      running = docker("inspect", "-f", "{{.State.Running}}", @config.proxy_container, allow_fail: true)
      unless @remote.dry_run? || running.out.strip == "true"
        raise Error, "kamal-proxy isn't running on #{@config.server} (looked for container " \
                     "'#{@config.proxy_container}'). Deploy any Kamal app once, or run `kamal proxy boot`."
      end
      net = docker("network", "inspect", @config.network, allow_fail: true)
      raise Error, "Docker network '#{@config.network}' not found on #{@config.server}" unless net.ok?
    end

    # Build, start, route, and clean up. Returns the new container name.
    # Private and auto-update settings come from the site (flag or .quickhost.yml) and otherwise
    # carry over from the version that is live now. track: { repo:, branch: } is where the files
    # came from, when that is a git remote.
    def deploy(site, source, track: nil, user: nil, password: nil)
      @credentials = nil
      current = site_info(site.name)&.meta || Meta.new
      @meta = meta = Meta.new(host: site.host, revision: source.revision, options: site.persisted_options,
                              repo: track && track[:repo], branch: track && track[:branch])
      meta.auto = resolve_auto(site, current, meta)
      meta.auth = resolve_auth(current, private: site.private, user: user, password: password)

      tag = version_tag(source.revision)
      container = "#{site.service}-#{tag}"
      image_ref = "#{site.image}:#{tag}"

      ctx = BuildContext.new(site)
      ctx.create
      tarball = File.join(Dir.tmpdir, "quickhost-#{site.name}-#{tag}.tgz")
      pack(ctx.dir, tarball)

      step "Building #{image_ref} on #{@config.server} (#{describe_mode(site)})"
      build = docker("build", "-t", image_ref, "--label", "#{Site::LABEL}=#{site.name}", "-",
                     input: tarball, stream: @verbose, allow_fail: true)
      unless build.ok?
        tail = (build.out + build.err).lines.last(25).map { |l| "  │ #{l}" }.join
        raise Error, "Build failed on #{@config.server}; the live site is unchanged.\n#{tail}"
      end

      begin
        start_and_route(site, image_ref, container, meta)
      rescue Error
        docker("rmi", image_ref, allow_fail: true)
        raise
      end
      cleanup_containers(site, keep: container)
      prune_images(site, keep_tag: tag)
      container
    ensure
      ctx&.cleanup
      File.delete(tarball) if tarball && File.exist?(tarball)
    end

    def rollback(site_name, to: nil)
      @credentials = nil
      site = StubSite.new(site_name, @config)
      info = site_info(site.name)
      tags = image_tags(site)
      current = info&.running? ? info.tag : nil
      raise Error, "No images found for #{site_name}" if tags.empty?

      target = to || tags.find { |t| current.nil? || t < current }
      raise Error, "Nothing older than #{current} to roll back to (kept: #{tags.join(', ')})" unless target
      raise Error, "No image #{site.image}:#{target} (kept: #{tags.join(', ')})" unless tags.include?(target)

      @meta = meta = (info&.meta || Meta.new).dup
      meta.host ||= site.host
      meta.revision = target.split("-", 2)[1]
      # Otherwise the updater would see the newer commit and put it straight back.
      if meta.auto?
        meta.auto = false
        @out.puts "⚠ Auto-updates turned off for #{site.name} so the rollback sticks. " \
                  "Turn them back on with: quickhost auto on #{site.name}"
      end
      site.host_override = meta.host
      container = "#{site.service}-#{target}-rb#{Time.now.utc.strftime('%H%M%S')}"
      start_and_route(site, "#{site.image}:#{target}", container, meta)
      cleanup_containers(site, keep: container)
      container
    end

    # Changes a live site's settings without rebuilding: starts the same version again with the
    # new settings, switches traffic to it, and removes the old container.
    #   private: true/false   password protect or open up (true always sets a password:
    #                         the one given, or a new generated one)
    #   auto:    true/false   follow new commits or not
    def reconfigure(site_name, private: nil, user: nil, password: nil, auto: nil)
      @credentials = nil
      site = StubSite.new(site_name, @config)
      info = site_info(site.name) or raise Error, "No site named #{site.name}. See: quickhost list"
      raise Error, "#{site.name} isn't running (#{info.state}); redeploy it first" unless info.running? || @remote.dry_run?

      @meta = meta = info.meta.dup
      meta.host ||= site.host
      unless auto.nil?
        if auto && !meta.repo
          raise Error, "#{site.name} has no git source recorded, so there's nothing to follow. " \
                       "Redeploy it from a repo with --auto (e.g. quickhost deploy owner/repo --auto)."
        end
        meta.auto = auto
      end
      meta.auth = resolve_auth(info.meta, private: private, user: user, password: password, fresh: true) unless private.nil?

      site.host_override = meta.host
      container = "#{site.service}-#{info.tag}-c#{Time.now.utc.strftime('%H%M%S')}"
      start_and_route(site, info.image, container, meta)
      cleanup_containers(site, keep: container)
      container
    end

    # Every quickhost site as a SiteInfo, sorted by name. With name:, just that site.
    def sites(name: nil)
      filter = name ? "label=#{Site::LABEL}=#{name}" : "label=#{Site::LABEL}"
      ids = docker("ps", "-aq", "--filter", filter).out.split
      return [] if ids.empty?

      infos = JSON.parse(docker("inspect", *ids).out).map { |data| SiteInfo.from_inspect(data) }
      # A site has one container, except briefly mid-deploy: prefer the running one, then the newest.
      infos.group_by(&:name).map { |_, group| group.max_by { |i| [i.running? ? 1 : 0, i.created] } }.sort_by(&:name)
    rescue JSON::ParserError
      raise Error, "Couldn't read site details from docker on #{@config.server}"
    end

    def site_info(name) = sites(name: Site.sanitize(name)).first

    # Version tags kept on the server for a site, newest first.
    def versions(name) = image_tags(StubSite.new(name, @config))

    def remove(name)
      site = StubSite.new(name, @config)
      step "Removing route #{site.service}"
      proxy("remove", site.service, allow_fail: true)
      step "Removing containers"
      site_containers(site).each { |c| docker("rm", "-f", c) }
      step "Removing images"
      image_tags(site).each { |t| docker("rmi", "#{site.image}:#{t}", allow_fail: true) }
    end

    def logs(name, follow: false, tail: 100)
      site = StubSite.new(name, @config)
      container = current_container(site) || raise(Error, "No running container for #{name}")
      args = ["logs", "--tail", tail.to_s]
      args << "-f" if follow
      docker(*args, container, stream: true)
    end

    def doctor
      checks = []
      checks << ["ssh #{@config.server}", @remote.run("true", allow_fail: true).ok?]
      ver = docker("version", "--format", "{{.Server.Version}}", allow_fail: true)
      checks << ["docker on server (#{ver.out.strip})", ver.ok?]
      running = docker("inspect", "-f", "{{.State.Running}}", @config.proxy_container, allow_fail: true)
      checks << ["#{@config.proxy_container} running", running.out.strip == "true"]
      checks << ["network #{@config.network}", docker("network", "inspect", @config.network, allow_fail: true).ok?]
      checks
    end

    def proxy_list
      proxy("list", allow_fail: true).out
    end

    private

    def start_and_route(site, image_ref, container, meta)
      step "Starting #{container}#{meta.private? ? ' (private)' : ''}"
      settings = meta.to_labels.flat_map { |key, value| ["--label", "#{key}=#{value}"] }
      settings += ["-e", "QH_AUTH=#{meta.auth}"] if meta.private?
      docker("run", "-d", "--name", container,
             "--network", @config.network,
             "--restart", "unless-stopped",
             "--label", "#{Site::LABEL}=#{site.name}",
             *settings,
             image_ref)
      verify_private!(site, container) if meta.private?

      step "Routing https://#{site.host} → #{container}"
      args = ["deploy", site.service, "--target", "#{container}:80", "--host", site.host]
      args << "--tls" if @config.tls
      result = proxy(*args, allow_fail: true)
      return if result.ok?

      docker("rm", "-f", container, allow_fail: true)
      hint = if result.err.include?("host is used by another service")
               "\nAnother app (maybe a Kamal deploy) already owns #{site.host}. Pick another --name or --domain."
             end
      raise Error, "kamal-proxy refused the deploy; old version is still live.\n#{result.err.strip}#{hint}"
    end

    # Before any traffic reaches a private container, make sure it really is asking for a
    # password. Versions built before quickhost 0.3 don't have the auth script and would
    # otherwise come up public.
    def verify_private!(site, container)
      wait = "for i in 1 2 3 4 5 6 7 8 9 10; do test -s #{BuildContext::AUTH_CONF} && exit 0; sleep 0.5; done; exit 1"
      return if docker("exec", container, "sh", "-c", wait, allow_fail: true).ok?

      docker("rm", "-f", container, allow_fail: true)
      raise Error, "Couldn't turn on password protection for #{site.name}: this version was built before " \
                   "quickhost supported private sites. Redeploy it with `quickhost deploy … --private`. " \
                   "Nothing has changed on the server."
    end

    # nil when the site should be public, else its htpasswd line.
    # fresh: always set a password (given or generated) instead of keeping the current one.
    def resolve_auth(current, private:, user: nil, password: nil, fresh: false)
      private = true if private.nil? && password
      private = current.private? if private.nil?
      return nil unless private

      keep = current.private? && !fresh && password.nil? && (user.nil? || user == current.user)
      return current.auth if keep

      user ||= current.user || @config.private_user
      generated = password.nil?
      password ||= Auth.generate_password
      @credentials = [user, password, generated]
      Auth.htpasswd(user, password)
    end

    def resolve_auto(site, current, meta)
      if site.auto && !meta.repo
        raise Error, "Auto-updates need a git remote to follow. Deploy from a GitHub URL or owner/repo, " \
                     "or from the root of a local repo that has an `origin` remote and a branch checked out."
      end
      return site.auto unless site.auto.nil?
      return false unless current.auto?
      return true if meta.repo

      @out.puts "⚠ Auto-updates turned off for #{site.name}: this deploy has no git remote to follow."
      false
    end

    def cleanup_containers(site, keep:)
      old = site_containers(site) - [keep]
      return if old.empty?

      step "Removing old containers: #{old.join(', ')}"
      old.each { |c| docker("rm", "-f", c, allow_fail: true) }
    end

    def prune_images(site, keep_tag:)
      extra = image_tags(site).reject { |t| t == keep_tag }.drop([@config.keep_images - 1, 0].max)
      extra.each { |t| docker("rmi", "#{site.image}:#{t}", allow_fail: true) }
    end

    def site_containers(site)
      docker("ps", "-a", "--filter", "label=#{Site::LABEL}=#{site.name}", "--format", "{{.Names}}")
        .out.split("\n").map(&:strip).reject(&:empty?)
    end

    def current_container(site)
      docker("ps", "--filter", "label=#{Site::LABEL}=#{site.name}", "--format", "{{.Names}}")
        .out.split("\n").map(&:strip).reject(&:empty?).first
    end

    # Newest first. Tags start with a UTC timestamp so string sort works.
    def image_tags(site)
      docker("image", "ls", site.image, "--format", "{{.Tag}}")
        .out.split("\n").map(&:strip).reject { |t| t.empty? || t == "<none>" }.sort.reverse
    end

    def version_tag(revision)
      [Time.now.utc.strftime("%Y%m%d%H%M%S"), revision].compact.join("-")
    end

    def describe_mode(site)
      case site.mode
      when :npm then "npm build"
      when :custom then "custom build: #{site.build_command}"
      when :docs then "static, docs/ folder"
      else "static#{site.static_dir == '.' ? '' : ", #{site.static_dir}/"}"
      end
    end

    def pack(dir, tarball)
      _out, err, status = Open3.capture3("tar", "-C", dir, "-czf", tarball, ".")
      raise Error, "Could not package build context: #{err}" unless status.success?
    end

    def docker(*args, **opts)
      @remote.run("docker", *args, **opts)
    end

    def proxy(*args, **opts)
      @remote.run("docker", "exec", @config.proxy_container, "kamal-proxy", *args, **opts)
    end

    def step(msg)
      @out.puts "→ #{msg}"
    end

    # Minimal site handle for commands that only know the name (remove, logs, rollback).
    class StubSite
      attr_accessor :host_override
      attr_reader :name

      def initialize(name, config)
        @name = Site.sanitize(name)
        @config = config
      end

      def service = "#{Site::SERVICE_PREFIX}#{name}"
      def image = "quickhost/#{name}"
      def host = host_override || "#{name}.#{@config.base_domain}"
    end
  end
end
