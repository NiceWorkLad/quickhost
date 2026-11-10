require "cgi"
require "net/http"
require "openssl"
require "time"
require "timeout"
require "tmpdir"
require "fileutils"

module Quickhost
  # A link-tree page listing every site kamal-proxy is routing: quickhost sites and Kamal apps alike.
  # The list comes from the live routes, and each site's <title>/description is fetched from the
  # site itself, so nothing has to be kept up to date by hand.
  class Hub
    Entry = Struct.new(:service, :host, :state, :title, :description, :status, keyword_init: true) do
      def quickhost? = service.start_with?(Site::SERVICE_PREFIX)
      def up? = status.is_a?(Integer) && status < 500   # a 404 at / (e.g. an API) still means it answered
      def url(scheme) = "#{scheme}://#{host}"
    end

    # Stand-in for Source: Deployer only asks a source for its revision.
    HubSource = Struct.new(:revision)

    FETCH_TIMEOUT = 6
    ANSI = /\e\[[\d;]*m/

    # routes_from: anything with #proxy_list (a Deployer on a live connection, so listing and
    # status checks work even when deploying is a dry run). deployer: what actually deploys.
    def initialize(config:, deployer:, routes_from: deployer, name: nil, out: $stdout)
      @config = config
      @deployer = deployer
      @routes_from = routes_from
      @name = Site.sanitize(name || config.hub_name)
      @out = out
    end

    attr_reader :name

    def host = "#{name}.#{@config.base_domain}"
    def scheme = @config.tls ? "https" : "http"

    # Parses `kamal-proxy list`, a table like:
    #   Service  Host                        Path  Target       State    TLS
    #   qh-blog  blog.example.com,b.example  /     qh-blog-1:80 running  yes
    def self.parse_routes(table)
      lines = table.to_s.gsub(ANSI, "").lines.map(&:rstrip).reject(&:empty?)
      header = lines.shift.to_s.split(/\s{2,}/).map(&:downcase)
      return [] unless header.include?("service") && header.include?("host")

      lines.filter_map do |line|
        row = header.zip(line.strip.split(/\s{2,}/)).to_h
        next if row["service"].to_s.empty? || row["host"].to_s.empty?

        { service: row["service"], host: row["host"].split(",").first.strip, state: row["state"].to_s }
      end
    end

    def entries
      @entries ||= begin
        hidden = Array(@config.hub_hide).flat_map { |h| h.to_s.split(",") }.map(&:strip)
        routes = self.class.parse_routes(@routes_from.proxy_list)
        routes.reject! do |r|
          r[:service] == "#{Site::SERVICE_PREFIX}#{name}" || r[:host] == host || self.class.keys_for(r).intersect?(hidden)
        end
        threads = routes.map { |r| Thread.new { describe(r) } }
        threads.map(&:value).sort_by { |e| e.title.downcase }
      end
    end

    # The names a site can be referred to by in hub_hide / hub_sites: its host, subdomain,
    # kamal-proxy service, and quickhost site name.
    def self.keys_for(route)
      [route[:host], route[:host].split(".").first, route[:service],
       route[:service].delete_prefix(Site::SERVICE_PREFIX)].uniq
    end

    def html(now: Time.now)
      HubPage.render(entries: entries, scheme: scheme, host: host, updated: now)
    end

    # Writes the page to a temp folder and deploys it like any static site.
    def deploy
      @out.puts "→ Collecting routes from #{@config.proxy_container} on #{@config.server}"
      list = entries
      list.each { |e| @out.puts "  #{e.up? ? '●' : '○'} #{e.title.ljust(28)} #{e.url(scheme)}" }
      raise Error, "No sites found in kamal-proxy's routes" if list.empty?

      Dir.mktmpdir("quickhost-hub-") do |dir|
        File.write(File.join(dir, "index.html"), html)
        site = Site.new(root: dir, config: @config, options: { "name" => name }, fallback_name: name)
        @deployer.preflight!
        @deployer.deploy(site, HubSource.new("hub"))
      end
      list
    end

    private

    def describe(route)
      status, body = fetch("#{scheme}://#{route[:host]}/")
      custom = override_for(route)
      title = custom.fetch("title", nil).to_s.strip
      description = custom.key?("description") ? clean(custom["description"]) : meta_description(body)
      Entry.new(**route, status: status,
                         title: title.empty? ? meta_title(body) || pretty_name(route) : title,
                         description: description)
    end

    # Per-site wording from hub_sites in the config, e.g.
    #   hub_sites:
    #     map: { title: Minecraft Map, description: Live 3D map of our server }
    # An empty description ("") removes the site's own one.
    def override_for(route)
      sites = @config.hub_sites
      return {} unless sites.is_a?(Hash)

      key = self.class.keys_for(route).find { |k| sites.key?(k) }
      key && sites[key].is_a?(Hash) ? sites[key].transform_keys(&:to_s) : {}
    end

    def fetch(url, redirects: 3)
      uri = URI(url)
      res = Timeout.timeout(FETCH_TIMEOUT * 2) do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: FETCH_TIMEOUT, read_timeout: FETCH_TIMEOUT) do |http|
          http.get(uri.request_uri, "User-Agent" => "quickhost-hub", "Accept" => "text/html")
        end
      end
      if res.is_a?(Net::HTTPRedirection) && redirects.positive? && res["location"]
        return fetch(URI.join(url, res["location"]).to_s, redirects: redirects - 1)
      end
      [res.code.to_i, res.body.to_s.byteslice(0, 2_000_000).force_encoding("UTF-8").scrub]
    rescue StandardError, Timeout::Error => e
      [e.class.name.split("::").last, ""]
    end

    def meta_title(body)
      clean(body[%r{<title[^>]*>(.*?)</title>}im, 1])
    end

    def meta_description(body)
      tag = body.scan(/<meta\b[^>]*>/i).find { |t| t.match?(/(name|property)\s*=\s*["'](og:)?description["']/i) }
      clean(tag && tag[/content\s*=\s*"([^"]*)"/i, 1] || tag && tag[/content\s*=\s*'([^']*)'/i, 1])
    end

    def clean(text)
      text = CGI.unescapeHTML(text.to_s).gsub(/\s+/, " ").strip
      text.empty? ? nil : text[0, 160]
    end

    def pretty_name(route)
      route[:host].split(".").first.split(/[-_]/).map(&:capitalize).join(" ")
    end
  end

  module HubPage
    module_function

    def h(s) = CGI.escapeHTML(s.to_s)

    def render(entries:, scheme:, host:, updated:)
      cards = entries.map { |e| card(e, scheme) }.join("\n")
      up = entries.count(&:up?)
      <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Sites</title>
        <meta name="description" content="Everything running on #{h(host.split('.', 2).last)}.">
        <style>
        :root {
          --bg: #f6f5f1; --card: #ffffff; --text: #1d1c1a; --muted: #6b6862; --line: #e4e1da;
          --accent: #2f6f5e; --up: #2e9b57; --down: #c2412d; --chip: #efede7;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #151514; --card: #1e1e1c; --text: #ecebe6; --muted: #9b988f; --line: #2e2d2a;
            --accent: #7cc4ad; --up: #4cc27a; --down: #e2674f; --chip: #2a2926;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; background: var(--bg); color: var(--text);
          font: 16px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
          -webkit-font-smoothing: antialiased;
        }
        main { max-width: 640px; margin: 0 auto; padding: 56px 16px 40px; }
        header { margin-bottom: 28px; }
        h1 { font-size: 28px; line-height: 1.2; margin: 0 0 6px; letter-spacing: -0.01em; }
        .sub { color: var(--muted); margin: 0; font-size: 15px; }
        ul { list-style: none; margin: 0; padding: 0; display: grid; gap: 10px; }
        a.card {
          display: grid; grid-template-columns: 40px 1fr auto; gap: 14px; align-items: center;
          padding: 14px 16px; border: 1px solid var(--line); border-radius: 12px;
          background: var(--card); color: inherit; text-decoration: none;
          transition: border-color .15s, transform .15s;
        }
        a.card:hover { border-color: var(--accent); transform: translateY(-1px); }
        a.card:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
        .icon {
          width: 40px; height: 40px; border-radius: 9px; background: var(--chip);
          display: grid; place-items: center; overflow: hidden;
          font-weight: 650; color: var(--accent); font-size: 17px;
        }
        .icon img { width: 24px; height: 24px; }
        .text { min-width: 0; }
        .title { font-weight: 600; display: flex; align-items: center; gap: 8px; }
        .title span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .desc { color: var(--muted); font-size: 14px; margin-top: 1px;
                display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
        .host { color: var(--muted); font-size: 13px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
                overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .dot { width: 8px; height: 8px; border-radius: 50%; flex: none; background: var(--up); }
        .dot.down { background: var(--down); }
        .arrow { color: var(--muted); font-size: 18px; }
        footer { margin-top: 28px; color: var(--muted); font-size: 13px; }
        @media (max-width: 420px) { .arrow { display: none; } a.card { grid-template-columns: 40px 1fr; } }
        </style>
        </head>
        <body>
        <main>
          <header>
            <h1>Sites</h1>
            <p class="sub">#{entries.size} #{entries.size == 1 ? 'site' : 'sites'} · #{up} up</p>
          </header>
          <ul>
        #{cards}
          </ul>
          <footer>Status checked <time datetime="#{updated.utc.iso8601}">#{h(updated.strftime('%-d %b %Y, %H:%M'))}</time>.</footer>
        </main>
        </body>
        </html>
      HTML
    end

    def card(e, scheme)
      url = e.url(scheme)
      initial = e.title[/[[:alnum:]]/].to_s.upcase
      status = e.up? ? "Up" : "Down (#{e.status})"
      desc = e.description ? %(\n          <div class="desc">#{h(e.description)}</div>) : ""
      <<~LI.chomp
        <li><a class="card" href="#{h(url)}">
          <div class="icon" aria-hidden="true"><img src="#{h(url)}/favicon.ico" alt="" loading="lazy" onerror="this.replaceWith(document.createTextNode('#{h(initial)}'))"></div>
          <div class="text">
          <div class="title"><span class="dot#{e.up? ? '' : ' down'}" title="#{h(status)}" role="img" aria-label="#{h(status)}"></span><span>#{h(e.title)}</span></div>#{desc}
          <div class="host">#{h(e.host)}</div>
          </div>
          <span class="arrow" aria-hidden="true">→</span>
        </a></li>
      LI
    end
  end
end
