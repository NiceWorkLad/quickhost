require "base64"
require "digest/sha1"
require "json"
require "securerandom"
require "time"

module Quickhost
  # Password protection for private sites: an nginx basic-auth line, hashed on this machine.
  # {SSHA} (salted SHA-1) is the one scheme nginx checks itself on every platform, and Ruby can
  # produce it without htpasswd or openssl installed.
  module Auth
    USER = /\A[\w.@-]{1,64}\z/

    module_function

    def htpasswd(user, password)
      raise Error, "Username #{user.inspect} can only use letters, digits and . _ @ -" unless user.to_s.match?(USER)
      raise Error, "Password can't be empty" if password.to_s.empty?

      salt = SecureRandom.random_bytes(8)
      "#{user}:{SSHA}#{Base64.strict_encode64(Digest::SHA1.digest(password.b + salt) + salt)}"
    end

    def generate_password = SecureRandom.alphanumeric(20)

    def matches?(line, password)
      raw = Base64.strict_decode64(line.to_s.split(":{SSHA}", 2).last.to_s)
      Digest::SHA1.digest(password.b + raw.byteslice(20..)) == raw.byteslice(0, 20)
    rescue ArgumentError
      false
    end
  end

  # What quickhost remembers about a live site. It is stored as Docker labels on the site's
  # container, so every machine you deploy from (and the updater on the server) sees the same thing.
  class Meta
    LABELS = {
      host: "quickhost.host",          # public hostname
      repo: "quickhost.repo",          # git URL the site was deployed from, if any
      branch: "quickhost.branch",      # branch followed by auto-updates (nil = the repo's default)
      revision: "quickhost.revision",  # short commit sha that is live
      auto: "quickhost.auto",          # "true" when the updater should redeploy new commits
      auth: "quickhost.auth",          # htpasswd line; present = the site is private
      options: "quickhost.options"     # JSON of the deploy flags (build, dir, spa, node_image)
    }.freeze

    attr_accessor(*LABELS.keys)

    def initialize(**fields)
      @options = {}
      fields.each { |k, v| public_send("#{k}=", v) }
    end

    def self.from_labels(labels)
      labels ||= {}
      get = ->(key) { v = labels[LABELS[key]].to_s; v.empty? ? nil : v }
      options = begin
        JSON.parse(get[:options] || "{}")
      rescue JSON::ParserError
        {}
      end
      new(host: get[:host], repo: get[:repo], branch: get[:branch], revision: get[:revision],
          auto: get[:auto] == "true", auth: get[:auth], options: options.is_a?(Hash) ? options : {})
    end

    def to_labels
      {
        LABELS[:host] => host, LABELS[:repo] => repo, LABELS[:branch] => branch, LABELS[:revision] => revision,
        LABELS[:auto] => (auto ? "true" : nil), LABELS[:auth] => auth,
        LABELS[:options] => (options.nil? || options.empty? ? nil : JSON.generate(options))
      }.reject { |_, v| v.to_s.empty? }
    end

    def private? = !auth.to_s.empty?
    def user = private? ? auth.split(":", 2).first : nil
    def auto? = auto == true
    def source_label = repo && "#{repo}#{branch ? " (#{branch})" : ''}"
  end

  # One deployed site, read back from `docker inspect`.
  SiteInfo = Struct.new(:name, :container, :image, :state, :created, :meta, keyword_init: true) do
    def self.from_inspect(data)
      labels = data.dig("Config", "Labels") || {}
      new(name: labels[Site::LABEL], container: data["Name"].to_s.delete_prefix("/"),
          image: data.dig("Config", "Image").to_s, state: data.dig("State", "Status").to_s,
          created: data["Created"].to_s, meta: Meta.from_labels(labels))
    end

    def running? = state == "running"
    def tag = image.include?(":") ? image.split(":").last : nil
    def host = meta.host

    # Version tags start with the UTC time of the deploy.
    def deployed_at
      stamp = tag.to_s[/\A\d{14}/] or return
      Time.strptime("#{stamp} UTC", "%Y%m%d%H%M%S %Z")
    rescue ArgumentError
      nil
    end

    def to_h(scheme)
      { name: name, url: "#{scheme}://#{host}", host: host, state: state, container: container,
        version: tag, deployed_at: deployed_at&.utc&.iso8601, private: meta.private?, user: meta.user,
        auto: meta.auto?, repo: meta.repo, branch: meta.branch, revision: meta.revision }
    end
  end
end
