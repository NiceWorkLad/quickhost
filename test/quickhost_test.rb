require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../lib/quickhost"

class FakeRemote
  attr_reader :log
  attr_accessor :responses

  def initialize
    @log = []
    @responses = {} # substring => Result
  end

  def dry_run? = false

  def run(*argv, input: nil, stream: false, allow_fail: false)
    cmd = argv.flatten.map(&:to_s).join(" ")
    @log << cmd
    hit = @responses.find { |k, _| cmd.include?(k) }&.last
    res = hit || Quickhost::Remote::Result.new(true, "", "")
    raise Quickhost::Error, "failed: #{cmd}" if !res.ok? && !allow_fail

    res
  end
end

module Helpers
  R = Quickhost::Remote::Result

  def config(**over)
    Quickhost::Config.new("/dev/null", Quickhost::Config::DEFAULTS.merge(over.transform_keys(&:to_s)))
  end

  def repo(files)
    dir = Dir.mktmpdir("qh-test-")
    files.each do |path, body|
      full = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, body)
    end
    dir
  end
end

class SiteTest < Minitest::Test
  include Helpers

  def test_sanitize
    assert_equal "ball-game", Quickhost::Site.sanitize("Ball-Game")
    assert_equal "my-site", Quickhost::Site.sanitize("My_Site.git")
    assert_equal "a-b", Quickhost::Site.sanitize("--A!!b--")
  end

  def test_default_host_uses_base_domain
    site = Quickhost::Site.new(root: repo("index.html" => "hi"), config: config, fallback_name: "Ball-Game")
    assert_equal "ball-game.whittleadams.com", site.host
    assert_equal "qh-ball-game", site.service
    assert_equal :static, site.mode
  end

  def test_domain_override
    site = Quickhost::Site.new(root: repo("index.html" => "hi"), config: config, options: { domain: "Blog.Example.com" })
    assert_equal "blog.example.com", site.host
  end

  def test_invalid_domain
    site = Quickhost::Site.new(root: repo("index.html" => "hi"), config: config, options: { domain: "not a host" })
    assert_raises(Quickhost::Error) { site.host }
  end

  def test_repo_config_and_cli_precedence
    root = repo("index.html" => "x", ".quickhost.yml" => "name: fromfile\ndomain: a.example.com\n")
    site = Quickhost::Site.new(root: root, config: config, options: { domain: "b.example.com" })
    assert_equal "fromfile", site.name
    assert_equal "b.example.com", site.host
  end

  def test_docs_mode
    site = Quickhost::Site.new(root: repo("docs/index.html" => "x"), config: config)
    assert_equal :docs, site.mode
    assert_equal "docs", site.static_dir
  end

  def test_npm_mode_detects_lockfile
    root = repo("package.json" => '{"scripts":{"build":"vite build"}}', "pnpm-lock.yaml" => "")
    site = Quickhost::Site.new(root: root, config: config)
    assert_equal :npm, site.mode
    assert_equal "corepack enable && pnpm install --frozen-lockfile && pnpm run build", site.build_command
  end

  def test_npm_without_build_script_falls_back_to_static
    root = repo("package.json" => '{"scripts":{}}', "index.html" => "x")
    assert_equal :static, Quickhost::Site.new(root: root, config: config).mode
  end

  def test_nothing_to_serve
    assert_raises(Quickhost::Error) { Quickhost::Site.new(root: repo("README.md" => "x"), config: config).mode }
  end
end

class BuildContextTest < Minitest::Test
  include Helpers

  def test_static_context_skips_git_and_node_modules
    root = repo("index.html" => "x", ".git/HEAD" => "ref", "node_modules/a.js" => "x")
    site = Quickhost::Site.new(root: root, config: config)
    ctx = Quickhost::BuildContext.new(site)
    dir = ctx.create
    assert File.exist?(File.join(dir, "src/index.html"))
    refute File.exist?(File.join(dir, "src/.git"))
    refute File.exist?(File.join(dir, "src/node_modules"))
    assert_includes File.read(File.join(dir, "Dockerfile")), "COPY src/ /usr/share/nginx/html/"
  ensure
    ctx&.cleanup
  end

  def test_spa_fallback
    site = Quickhost::Site.new(root: repo("index.html" => "x"), config: config, options: { spa: true })
    assert_includes Quickhost::BuildContext.new(site).nginx_conf, "try_files $uri $uri/ $uri.html /index.html;"
  end

  def test_build_dockerfile_uses_custom_dir
    site = Quickhost::Site.new(root: repo("a" => "b"), config: config, options: { build: "make site", dir: "out dir" })
    df = Quickhost::BuildContext.new(site).dockerfile
    assert_includes df, "RUN make site"
    assert_includes df, "cp -a out\\ dir/. /site/"
  end
end

class DeployerTest < Minitest::Test
  include Helpers

  def setup
    @remote = FakeRemote.new
    @out = StringIO.new
    @deployer = Quickhost::Deployer.new(config: config, remote: @remote, out: @out)
  end

  def source_for(root)
    Quickhost::Source.new(root).prepare
  end

  def test_deploy_sequence
    root = repo("index.html" => "hi")
    site = Quickhost::Site.new(root: root, config: config, fallback_name: "ball-game")
    @remote.responses["ps -a --filter label=quickhost.site=ball-game"] = R.new(true, "qh-ball-game-old\n", "")
    @remote.responses["image ls quickhost/ball-game"] = R.new(true, "4\n3\n2\n1\n", "")

    container = @deployer.deploy(site, source_for(root))

    log = @remote.log.join("\n")
    assert_match(/docker build -t quickhost\/ball-game:\d{14} --label quickhost.site=ball-game -/, log)
    assert_includes log, "docker run -d --name #{container} --network kamal --restart unless-stopped"
    assert_includes log, "docker exec kamal-proxy kamal-proxy deploy qh-ball-game --target #{container}:80 --host ball-game.whittleadams.com --tls"
    assert_includes log, "docker rm -f qh-ball-game-old"
    # keeps the new image + 2 newest old ones (keep_images = 3)
    assert_includes log, "docker rmi quickhost/ball-game:2"
    assert_includes log, "docker rmi quickhost/ball-game:1"
    refute_includes log, "docker rmi quickhost/ball-game:4"
    # routing happens before old containers are removed
    assert log.index("kamal-proxy deploy") < log.index("rm -f qh-ball-game-old")
  end

  def test_failed_route_keeps_old_version
    root = repo("index.html" => "hi")
    site = Quickhost::Site.new(root: root, config: config, fallback_name: "taken")
    @remote.responses["kamal-proxy deploy"] = R.new(false, "", "Error: host is used by another service")
    @remote.responses["ps -a --filter label=quickhost.site=taken"] = R.new(true, "qh-taken-old\n", "")

    err = assert_raises(Quickhost::Error) { @deployer.deploy(site, source_for(root)) }
    assert_includes err.message, "already owns taken.whittleadams.com"
    log = @remote.log.join("\n")
    refute_includes log, "rm -f qh-taken-old"
    assert_match(/docker rm -f qh-taken-\d{14}/, log)
  end

  def test_failed_build_never_touches_live_site
    root = repo("index.html" => "hi")
    site = Quickhost::Site.new(root: root, config: config, fallback_name: "blog")
    @remote.responses["docker build"] = R.new(false, "", "npm ERR! missing script\n")
    err = assert_raises(Quickhost::Error) { @deployer.deploy(site, source_for(root)) }
    assert_includes err.message, "live site is unchanged"
    assert_includes err.message, "npm ERR!"
    refute(@remote.log.any? { |c| c.include?("docker run") || c.include?("kamal-proxy deploy") })
  end

  def test_no_tls_flag_when_disabled
    d = Quickhost::Deployer.new(config: config(tls: false), remote: @remote, out: @out)
    root = repo("index.html" => "hi")
    d.deploy(Quickhost::Site.new(root: root, config: config(tls: false)), source_for(root))
    refute_includes @remote.log.find { |c| c.include?("kamal-proxy deploy") }, "--tls"
  end

  def test_preflight_fails_without_proxy
    @remote.responses["inspect -f"] = R.new(true, "false\n", "")
    assert_raises(Quickhost::Error) { @deployer.preflight! }
  end

  def test_rollback_picks_previous_image
    @remote.responses["docker ps --filter label=quickhost.site=blog"] = R.new(true, "qh-blog-20261110120000\n", "")
    @remote.responses["{{.Config.Image}}"] = R.new(true, "quickhost/blog:20261110120000\n", "")
    @remote.responses["quickhost.host"] = R.new(true, "blog.example.com\n", "")
    @remote.responses["image ls quickhost/blog"] = R.new(true, "20261110120000\n20261109120000\n20261108120000\n", "")

    @deployer.rollback("blog")
    log = @remote.log.join("\n")
    assert_includes log, "quickhost/blog:20261109120000"
    assert_includes log, "--host blog.example.com"
  end

  def test_remove
    @remote.responses["ps -a --filter label=quickhost.site=blog"] = R.new(true, "qh-blog-1\n", "")
    @remote.responses["image ls quickhost/blog"] = R.new(true, "1\n", "")
    @deployer.remove("blog")
    log = @remote.log.join("\n")
    assert_includes log, "kamal-proxy remove qh-blog"
    assert_includes log, "docker rm -f qh-blog-1"
    assert_includes log, "docker rmi quickhost/blog:1"
  end
end

class SourceTest < Minitest::Test
  def test_shorthand_becomes_github_url
    s = Quickhost::Source.new("NiceWorkLad/Ball-Game")
    assert s.remote?
    assert_equal "https://github.com/NiceWorkLad/Ball-Game.git", s.url
  end

  def test_existing_folder_is_local
    Dir.mktmpdir do |d|
      refute Quickhost::Source.new(d).remote?
    end
  end
end
