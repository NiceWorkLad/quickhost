require "yaml"
require "fileutils"

module Quickhost
  # Global settings, read from ~/.config/quickhost/config.yml (or $QUICKHOST_CONFIG)
  # and overridable with QUICKHOST_* environment variables.
  class Config
    DEFAULTS = {
      "server"          => "niceworklad@srv-01",   # ssh target that runs Docker + kamal-proxy
      "base_domain"     => "whittleadams.com",     # sites land on <name>.<base_domain>
      "network"         => "kamal",                # docker network kamal-proxy is attached to
      "proxy_container" => "kamal-proxy",          # name of the running kamal-proxy container
      "tls"             => true,                   # let kamal-proxy fetch Let's Encrypt certs
      "keep_images"     => 3,                      # old images kept per site for rollback
      "hub_name"        => "sites",                # `quickhost hub` lands on <hub_name>.<base_domain>
      "hub_hide"        => [],                     # sites to leave off the hub: name, host, or subdomain
      "hub_sites"       => {},                     # per-site hub wording: { map: { title:, description: } }
      "auth_user"       => nil,                    # sign-in for private sites (`private: true` / --private)
      "auth_password"   => nil
    }.freeze

    ENV_KEYS = DEFAULTS.keys.to_h { |k| [k, "QUICKHOST_#{k.upcase}"] }.freeze

    attr_reader :path, :values

    def self.default_path
      ENV["QUICKHOST_CONFIG"] || File.join(Dir.home, ".config", "quickhost", "config.yml")
    end

    def self.load(path = default_path, env: ENV)
      file_values = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
      raise Error, "#{path} must be a YAML mapping" unless file_values.is_a?(Hash)

      values = DEFAULTS.merge(file_values.transform_keys(&:to_s))
      ENV_KEYS.each do |key, env_key|
        values[key] = cast(key, env[env_key]) if env[env_key] && !env[env_key].empty?
      end
      new(path, values)
    end

    def self.cast(key, raw)
      case DEFAULTS[key]
      when true, false then %w[1 true yes on].include?(raw.to_s.downcase)
      when Integer     then Integer(raw)
      else raw
      end
    end

    def initialize(path, values)
      @path = path
      @values = values
    end

    DEFAULTS.each_key do |key|
      define_method(key) { values[key] }
    end

    def write!
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, YAML.dump(values))
      File.chmod(0o600, path) # it can hold auth_password
    end
  end
end
