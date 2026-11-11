require "json"
require "yaml"

module Quickhost
  # Everything about one site: its name, public host, and how to turn the repo into static files.
  class Site
    SERVICE_PREFIX = "qh-".freeze                  # keeps our services apart from Kamal apps
    OUTPUT_DIRS = %w[dist build out _site public www].freeze
    REPO_CONFIG = ".quickhost.yml".freeze
    LABEL = "quickhost.site".freeze

    # cli_options: only what was passed on the command line, which is what a later sync must repeat
    # (the repo's own .quickhost.yml is read again from the new commit).
    attr_reader :name, :root, :options, :cli_options

    # options (all optional; CLI flags beat .quickhost.yml):
    #   name, domain, build, dir, spa, node_image
    def initialize(root:, config:, options: {}, fallback_name: nil)
      @root = File.expand_path(root)
      @config = config
      @cli_options = options.compact.transform_keys(&:to_s)
      @options = repo_options.merge(@cli_options)
      @name = self.class.sanitize(@options["name"] || fallback_name || File.basename(@root))
      raise Error, "Could not work out a site name; pass --name" if @name.empty?
    end

    def self.sanitize(raw)
      raw.to_s.downcase.sub(/\.git\z/, "").gsub(/[^a-z0-9-]+/, "-").gsub(/-+/, "-").gsub(/\A-|-\z/, "")[0, 50].to_s.sub(/-\z/, "")
    end

    # Full public hostname. --domain is used as-is (e.g. "example.com" or "blog.example.com").
    def host
      domain = options["domain"].to_s.strip.downcase
      host = domain.empty? ? "#{name}.#{@config.base_domain}" : domain
      unless host.match?(/\A(?=.{1,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/)
        raise Error, "#{host.inspect} is not a valid hostname"
      end
      host
    end

    def service
      "#{SERVICE_PREFIX}#{name}"
    end

    def image
      "quickhost/#{name}"
    end

    def spa?
      options["spa"] == true || options["spa"].to_s == "true"
    end

    # :custom  — user-supplied build command (+ optional output dir)
    # :npm     — package.json with a "build" script
    # :static  — index.html in the repo root
    # :docs    — docs/index.html (GitHub Pages "docs folder" style)
    def mode
      @mode ||=
        if options["build"] then :custom
        elsif npm_build? then :npm
        elsif options["dir"] then :static
        elsif File.exist?(File.join(root, "index.html")) then :static
        elsif File.exist?(File.join(root, "docs", "index.html")) then :docs
        else
          raise Error, "Don't know how to serve #{root}: no index.html, docs/index.html, or package.json build script. " \
                       "Use --build \"<command>\" and --dir <output folder>."
        end
    end

    # Folder (relative to repo root) whose contents get served, for modes that need no build.
    def static_dir
      case mode
      when :docs then "docs"
      when :static then options["dir"] || "."
      end
    end

    def build_command
      return options["build"] if mode == :custom
      return unless mode == :npm

      "#{install_command} && #{runner} run build"
    end

    def install_command
      if exists?("pnpm-lock.yaml") then "corepack enable && pnpm install --frozen-lockfile"
      elsif exists?("yarn.lock") then "corepack enable && yarn install --frozen-lockfile"
      elsif exists?("bun.lockb") || exists?("bun.lock") then "npm install -g bun && bun install"
      elsif exists?("package-lock.json") then "npm ci"
      else "npm install"
      end
    end

    # Where to look for the build's index.html, in order. A Capacitor/Ionic app's configured
    # webDir comes first; the repo root is checked last (by the Dockerfile) for builds that
    # write index.html in place, GitHub Pages style.
    def output_dirs
      ([capacitor_web_dir] + OUTPUT_DIRS).compact.uniq
    end

    def node_image
      options["node_image"] || "node:22-alpine"
    end

    private

    def runner
      if exists?("pnpm-lock.yaml") then "pnpm"
      elsif exists?("yarn.lock") then "yarn"
      elsif exists?("bun.lockb") || exists?("bun.lock") then "bun"
      else "npm"
      end
    end

    def exists?(rel)
      File.exist?(File.join(root, rel))
    end

    def npm_build?
      pkg = File.join(root, "package.json")
      return false unless File.exist?(pkg)

      JSON.parse(File.read(pkg)).dig("scripts", "build").to_s.strip != ""
    rescue JSON::ParserError
      false
    end

    def capacitor_web_dir
      path = File.join(root, "capacitor.config.json")
      return unless File.exist?(path)

      dir = JSON.parse(File.read(path))["webDir"].to_s.sub(%r{\A\./}, "").chomp("/")
      dir if dir.match?(%r{\A[\w.-]+(/[\w.-]+)*\z}) && !dir.split("/").include?("..") && dir != "."
    rescue JSON::ParserError
      nil
    end

    def repo_options
      path = File.join(root, REPO_CONFIG)
      return {} unless File.exist?(path)

      data = YAML.safe_load_file(path) || {}
      raise Error, "#{REPO_CONFIG} must be a YAML mapping" unless data.is_a?(Hash)

      data.transform_keys(&:to_s)
    end
  end
end
