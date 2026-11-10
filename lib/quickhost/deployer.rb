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
    def deploy(site, source)
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
        start_and_route(site, image_ref, container)
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
      site = StubSite.new(site_name, @config)
      tags = image_tags(site)
      current = current_tag(site)
      raise Error, "No images found for #{site_name}" if tags.empty?

      target = to || tags.find { |t| current.nil? || t < current }
      raise Error, "Nothing older than #{current} to roll back to (kept: #{tags.join(', ')})" unless target
      raise Error, "No image #{site.image}:#{target} (kept: #{tags.join(', ')})" unless tags.include?(target)

      host = current_host(site) || site.host
      site.host_override = host
      container = "#{site.service}-#{target}-rb#{Time.now.utc.strftime('%H%M%S')}"
      start_and_route(site, "#{site.image}:#{target}", container)
      cleanup_containers(site, keep: container)
      container
    end

    def list
      docker("ps", "-a", "--filter", "label=#{Site::LABEL}",
             "--format", "{{.Label \"#{Site::LABEL}\"}}\t{{.Label \"quickhost.host\"}}\t{{.Image}}\t{{.Status}}").out
    end

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

    def start_and_route(site, image_ref, container)
      step "Starting #{container}"
      docker("run", "-d", "--name", container,
             "--network", @config.network,
             "--restart", "unless-stopped",
             "--label", "#{Site::LABEL}=#{site.name}",
             "--label", "quickhost.host=#{site.host}",
             image_ref)

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

    def current_tag(site)
      c = current_container(site) or return
      ref = docker("inspect", "-f", "{{.Config.Image}}", c, allow_fail: true).out.strip
      ref.include?(":") ? ref.split(":").last : nil
    end

    def current_host(site)
      c = current_container(site) or return
      h = docker("inspect", "-f", "{{index .Config.Labels \"quickhost.host\"}}", c, allow_fail: true).out.strip
      h.empty? ? nil : h
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
