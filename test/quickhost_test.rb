require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require "json"
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

  # What `docker inspect` returns for a site's container.
  def inspect_json(name, tag, labels = {}, state: "running")
    JSON.generate([{ "Name" => "/qh-#{name}-#{tag}", "Created" => "2026-11-10T12:00:00Z",
                     "State" => { "Status" => state },
                     "Config" => { "Image" => "quickhost/#{name}:#{tag}",
                                   "Labels" => { "quickhost.site" => name }.merge(labels) } }])
  end

  def live(name, tag, labels = {})
    @remote.responses["ps -aq --filter label=quickhost.site=#{name}"] = R.new(true, "abc123\n", "")
    @remote.responses["docker inspect abc123"] = R.new(true, inspect_json(name, tag, labels), "")
  end

  def test_rollback_picks_previous_image
    live("blog", "20261110120000", "quickhost.host" => "blog.example.com")
    @remote.responses["image ls quickhost/blog"] = R.new(true, "20261110120000\n20261109120000-abc1234\n20261108120000\n", "")

    @deployer.rollback("blog")
    log = @remote.log.join("\n")
    assert_includes log, "quickhost/blog:20261109120000-abc1234"
    assert_includes log, "--host blog.example.com"
    assert_includes log, "--label quickhost.revision=abc1234"
  end

  def test_rollback_turns_auto_updates_off_and_keeps_password
    live("blog", "2", "quickhost.host" => "blog.example.com", "quickhost.auto" => "true",
                      "quickhost.repo" => "https://github.com/a/blog.git", "quickhost.auth" => "me:{SSHA}xyz")
    @remote.responses["image ls quickhost/blog"] = R.new(true, "2\n1\n", "")

    @deployer.rollback("blog")
    run = @remote.log.find { |c| c.start_with?("docker run") }
    refute_includes run, "quickhost.auto"
    assert_includes run, "QH_AUTH=me:{SSHA}xyz"
    assert_includes @out.string, "quickhost auto on blog"
  end

  def test_private_deploy_generates_password_and_checks_before_routing
    root = repo("index.html" => "hi")
    site = Quickhost::Site.new(root: root, config: config, options: { private: true }, fallback_name: "notes")
    @deployer.deploy(site, source_for(root))

    user, password, generated = @deployer.credentials
    assert_equal "quickhost", user
    assert generated
    assert_equal 20, password.size
    assert Quickhost::Auth.matches?(@deployer.meta.auth, password)
    refute Quickhost::Auth.matches?(@deployer.meta.auth, "wrong")
    log = @remote.log.join("\n")
    assert_includes log, "-e QH_AUTH=#{@deployer.meta.auth}"
    assert_includes log, "--label quickhost.auth=#{@deployer.meta.auth}"
    assert log.index("test -s /etc/nginx/quickhost/auth.conf") < log.index("kamal-proxy deploy"),
           "password protection is confirmed before traffic is switched"
  end

  def test_private_setting_sticks_across_deploys_with_the_same_password
    live("notes", "1", "quickhost.auth" => "me:{SSHA}old")
    root = repo("index.html" => "hi")
    @deployer.deploy(Quickhost::Site.new(root: root, config: config, fallback_name: "notes"), source_for(root))
    assert_nil @deployer.credentials
    assert_includes @remote.log.join("\n"), "QH_AUTH=me:{SSHA}old"
  end

  def test_public_flag_removes_password
    live("notes", "1", "quickhost.auth" => "me:{SSHA}old")
    root = repo("index.html" => "hi")
    site = Quickhost::Site.new(root: root, config: config, options: { private: false }, fallback_name: "notes")
    @deployer.deploy(site, source_for(root))
    refute_includes @remote.log.join("\n"), "QH_AUTH"
  end

  def test_private_refused_when_version_has_no_auth_script
    live("old", "1", "quickhost.host" => "old.whittleadams.com")
    @remote.responses["test -s /etc/nginx/quickhost/auth.conf"] = R.new(false, "", "")
    err = assert_raises(Quickhost::Error) { @deployer.reconfigure("old", private: true) }
    assert_includes err.message, "Redeploy"
    log = @remote.log.join("\n")
    refute_includes log, "kamal-proxy deploy"
    assert_match(/docker rm -f qh-old-1-c\d{6}/, log)
  end

  def test_reconfigure_private_restarts_same_version_with_given_password
    live("blog", "7", "quickhost.host" => "b.example.com", "quickhost.repo" => "https://github.com/a/b.git")
    @deployer.reconfigure("blog", private: true, user: "louis", password: "s3cret")
    assert_equal ["louis", "s3cret", false], @deployer.credentials
    assert Quickhost::Auth.matches?(@deployer.meta.auth, "s3cret")
    run = @remote.log.find { |c| c.start_with?("docker run") }
    assert_includes run, "quickhost/blog:7"
    assert_includes run, "--label quickhost.repo=https://github.com/a/b.git"
    assert_includes @remote.log.join("\n"), "--host b.example.com"
  end

  def test_auto_needs_a_git_source
    live("blog", "7")
    assert_raises(Quickhost::Error) { @deployer.reconfigure("blog", auto: true) }
    root = repo("index.html" => "hi")
    site = Quickhost::Site.new(root: root, config: config, options: { auto: true }, fallback_name: "x")
    assert_raises(Quickhost::Error) { @deployer.deploy(site, source_for(root)) }
  end

  def test_auto_deploy_records_source_and_flags
    root = repo("index.html" => "hi")
    site = Quickhost::Site.new(root: root, config: config, options: { auto: true, spa: true }, fallback_name: "x")
    @deployer.deploy(site, source_for(root), track: { repo: "https://github.com/a/x.git", branch: "main" })
    run = @remote.log.find { |c| c.start_with?("docker run") }
    assert_includes run, "--label quickhost.auto=true"
    assert_includes run, "--label quickhost.repo=https://github.com/a/x.git --label quickhost.branch=main"
    assert_includes run, %(quickhost.options={"spa":true})
  end

  def test_sites_prefers_running_container
    two = JSON.parse(inspect_json("blog", "1", {}, state: "exited")) + JSON.parse(inspect_json("blog", "2", { "quickhost.auth" => "u:{SSHA}h" }))
    @remote.responses["ps -aq --filter label=quickhost.site"] = R.new(true, "a\nb\n", "")
    @remote.responses["docker inspect a b"] = R.new(true, JSON.generate(two), "")
    sites = @deployer.sites
    assert_equal 1, sites.size
    assert_equal "2", sites.first.tag
    assert sites.first.meta.private?
    assert_equal "u", sites.first.meta.user
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

class UpdaterTest < Minitest::Test
  include Helpers

  Info = Quickhost::SiteInfo

  class FakeDeployer
    attr_reader :deployed
    attr_accessor :sites, :fail

    def initialize = @deployed = []

    def deploy(site, source, track: nil, **)
      raise Quickhost::Error, "build broke" if @fail

      @deployed << [site.name, site.host, site.spa?, source.revision, track]
    end
  end

  def setup
    @origin = repo("index.html" => "v1")
    system("git", "-C", @origin, "init", "-q", "-b", "main")
    commit("one")
    @deployer = FakeDeployer.new
    @out = StringIO.new
    @updater = Quickhost::Updater.new(config: config, deployer: @deployer, out: @out)
  end

  def teardown = FileUtils.rm_rf(@origin)

  def commit(msg)
    system("git", "-C", @origin, "add", "-A")
    system("git", "-C", @origin, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", msg)
    `git -C #{@origin} rev-parse --short HEAD`.strip
  end

  def site(name, revision, auto: true, options: {})
    meta = Quickhost::Meta.new(host: "#{name}.example.com", repo: "file://#{@origin}", branch: "main",
                               revision: revision, auto: auto, options: options)
    Info.new(name: name, container: "qh-#{name}-1", image: "quickhost/#{name}:1", state: "running", meta: meta)
  end

  def test_up_to_date_site_is_left_alone
    head = `git -C #{@origin} rev-parse --short HEAD`.strip
    @deployer.sites = [site("blog", head)]
    assert_equal [:current], @updater.run.map(&:result)
    assert_empty @deployer.deployed
  end

  def test_new_commit_redeploys_with_same_name_host_and_flags
    old = `git -C #{@origin} rev-parse --short HEAD`.strip
    File.write(File.join(@origin, "index.html"), "v2")
    new = commit("two")
    @deployer.sites = [site("blog", old, options: { "spa" => true }), site("manual", old, auto: false)]

    assert_equal [:updated], @updater.run.map(&:result)
    assert_equal [["blog", "blog.example.com", true, new, { repo: "file://#{@origin}", branch: "main" }]], @deployer.deployed
  end

  def test_named_site_updates_even_with_auto_off_and_force_redeploys
    head = `git -C #{@origin} rev-parse --short HEAD`.strip
    @deployer.sites = [site("manual", head, auto: false)]
    assert_equal [:current], @updater.run(names: ["manual"]).map(&:result)
    assert_equal [:updated], @updater.run(names: ["manual"], force: true).map(&:result)
    assert_raises(Quickhost::Error) { @updater.run(names: ["nope"]) }
  end

  def test_failed_commit_is_not_retried_until_a_new_one_arrives
    @deployer.sites = [site("blog", "0000000")]
    @deployer.fail = true
    assert_equal [:failed], @updater.run(remember_failures: true).map(&:result)
    assert_equal [:skipped], @updater.run(remember_failures: true).map(&:result)
    @deployer.fail = false
    File.write(File.join(@origin, "index.html"), "fixed")
    commit("fix")
    assert_equal [:updated], @updater.run(remember_failures: true).map(&:result)
  end

  def test_intervals
    assert_equal 300, Quickhost::Updater.parse_interval("5m")
    assert_equal 90, Quickhost::Updater.parse_interval("90")
    assert_equal 7200, Quickhost::Updater.parse_interval("2h")
    assert_equal "5m", Quickhost::Updater.format_interval(300)
    assert_equal "90s", Quickhost::Updater.format_interval(90)
    assert_raises(Quickhost::Error) { Quickhost::Updater.parse_interval("5") }
    assert_raises(Quickhost::Error) { Quickhost::Updater.parse_interval("soon") }
  end

  def test_updater_service_start_passes_config_and_mounts_docker
    remote = FakeRemote.new
    Quickhost::UpdaterService.new(config: config(base_domain: "x.com"), remote: remote, out: @out).start(interval: 120)
    log = remote.log.join("\n")
    assert_includes log, "docker build -t quickhost/updater:#{Quickhost::VERSION} -"
    run = remote.log.find { |c| c.start_with?("docker run") }
    assert_includes run, "-v /var/run/docker.sock:/var/run/docker.sock"
    assert_includes run, "-e QUICKHOST_BASE_DOMAIN=x.com"
    assert_includes run, "--label quickhost.interval=120"
    assert run.end_with?("update --watch 120")
  end
end

class TrackingTest < Minitest::Test
  def test_public_url
    assert_equal "https://github.com/a/b.git", Quickhost::Source.public_url("git@github.com:a/b.git")
    assert_equal "https://github.com/a/b.git", Quickhost::Source.public_url("ssh://git@github.com/a/b.git")
    assert_equal "https://github.com/a/b.git", Quickhost::Source.public_url("https://tok3n@github.com/a/b.git")
    assert_equal "https://github.com/a/b.git", Quickhost::Source.public_url("https://github.com/a/b.git")
  end

  def test_remote_source_tracks_its_url
    assert_equal({ repo: "https://github.com/NiceWorkLad/Ball-Game.git", branch: "dev" },
                 Quickhost::Source.new("NiceWorkLad/Ball-Game", branch: "dev").tracking)
  end

  def test_local_repo_tracks_origin_and_current_branch
    dir = Dir.mktmpdir("qh-track-")
    File.write(File.join(dir, "index.html"), "x")
    assert_nil Quickhost::Source.new(dir).prepare.tracking, "plain folder"
    system("git", "-C", dir, "init", "-q", "-b", "trunk")
    assert_nil Quickhost::Source.new(dir).prepare.tracking, "no origin"
    system("git", "-C", dir, "remote", "add", "origin", "git@github.com:a/site.git")
    assert_equal({ repo: "https://github.com/a/site.git", branch: "trunk" }, Quickhost::Source.new(dir).prepare.tracking)
    FileUtils.mkdir_p(File.join(dir, "sub"))
    assert_nil Quickhost::Source.new(File.join(dir, "sub")).prepare.tracking, "subfolder"
  ensure
    FileUtils.rm_rf(dir)
  end
end

class PrivateBuildTest < Minitest::Test
  include Helpers

  def test_every_image_can_be_made_private
    site = Quickhost::Site.new(root: repo("index.html" => "hi"), config: config)
    ctx = Quickhost::BuildContext.new(site)
    dir = ctx.create
    assert_includes ctx.dockerfile, "chmod 755 /docker-entrypoint.d/40-quickhost-auth.sh"
    assert_includes ctx.nginx_conf, "include /etc/nginx/quickhost/*.conf;"
    assert_includes ctx.nginx_conf, "location = /up { auth_basic off;"
    assert File.executable?(File.join(dir, "auth.sh"))
  ensure
    ctx&.cleanup
  end

  # Runs the real script (with /etc paths pointed at a temp folder) the way the container would.
  def test_auth_script_writes_and_clears_config
    dir = Dir.mktmpdir("qh-auth-")
    script = Quickhost::BuildContext::AUTH_SCRIPT.gsub(Quickhost::BuildContext::AUTH_DIR, dir)
    line = Quickhost::Auth.htpasswd("me", "pa$$ word'\"")
    assert system({ "QH_AUTH" => line }, "sh", "-c", script)
    assert_equal "#{line}\n", File.read(File.join(dir, "htpasswd"))
    assert_equal %(auth_basic "Private site";\nauth_basic_user_file #{dir}/htpasswd;\n), File.read(File.join(dir, "auth.conf"))
    assert system({ "QH_AUTH" => nil }, "sh", "-c", script)
    refute File.exist?(File.join(dir, "auth.conf")), "restarting without a password makes the site public again"
  ensure
    FileUtils.rm_rf(dir)
  end

  def test_repo_config_can_ask_for_private_and_flags_win
    root = repo("index.html" => "x", ".quickhost.yml" => "private: true\nauto: false\n")
    site = Quickhost::Site.new(root: root, config: config)
    assert_equal true, site.private
    assert_equal false, site.auto
    assert_equal false, Quickhost::Site.new(root: root, config: config, options: { private: false }).private
    plain = Quickhost::Site.new(root: repo("index.html" => "x"), config: config, options: { spa: true, name: "n" })
    assert_nil plain.private
    assert_equal({ "spa" => true }, plain.persisted_options)
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

class LocalBranchTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("qh-branch-")
    @repo = File.join(@dir, "Ball-Game")
    FileUtils.mkdir_p(File.join(@repo, "site"))
    sh "init", "-q", "-b", "main"
    File.write(File.join(@repo, "index.html"), "main")
    File.write(File.join(@repo, "site", "index.html"), "main-sub")
    sh "add", "."
    sh "commit", "-qm", "main"
    sh "checkout", "-qb", "dev"
    File.write(File.join(@repo, "index.html"), "dev")
    File.write(File.join(@repo, "site", "index.html"), "dev-sub")
    sh "commit", "-qam", "dev"
    sh "checkout", "-q", "main"
    File.write(File.join(@repo, "index.html"), "uncommitted")
  end

  def teardown = FileUtils.rm_rf(@dir)

  def sh(*args)
    system("git", "-C", @repo, "-c", "user.name=t", "-c", "user.email=t@t", *args, exception: true)
  end

  def test_exports_other_branch_without_touching_checkout
    s = Quickhost::Source.new(@repo, branch: "dev").prepare
    assert s.exported_branch?
    refute s.dirty?
    assert_equal "Ball-Game", s.repo_name
    assert_equal "dev", File.read(File.join(s.root, "index.html"))
    refute File.exist?(File.join(s.root, ".git"))
    out, = Open3.capture2("git", "-C", @repo, "rev-parse", "--short", "dev")
    assert_equal out.strip, s.revision
    # the user's working tree is untouched
    assert_equal "uncommitted", File.read(File.join(@repo, "index.html"))
    out, = Open3.capture2("git", "-C", @repo, "branch", "--show-current")
    assert_equal "main", out.strip
    root = s.root
    s.cleanup
    refute File.exist?(root)
  end

  def test_subfolder_exports_that_subfolder_of_branch
    s = Quickhost::Source.new(File.join(@repo, "site"), branch: "dev").prepare
    assert_equal "dev-sub", File.read(File.join(s.root, "index.html"))
    s.cleanup
  end

  def test_falls_back_to_origin_branch
    sh "update-ref", "refs/remotes/origin/feature", "dev"
    sh "branch", "-qD", "dev"
    s = Quickhost::Source.new(@repo, branch: "feature").prepare
    assert_equal "dev", File.read(File.join(s.root, "index.html"))
    s.cleanup
  end

  def test_unknown_branch_errors
    err = assert_raises(Quickhost::Error) { Quickhost::Source.new(@repo, branch: "nope").prepare }
    assert_match(/No branch or commit named 'nope'/, err.message)
  end

  def test_non_git_folder_errors
    Dir.mktmpdir do |d|
      err = assert_raises(Quickhost::Error) { Quickhost::Source.new(d, branch: "dev").prepare }
      assert_match(/needs .* to be a git repo/, err.message)
    end
  end

  def test_without_branch_uses_folder_on_disk
    s = Quickhost::Source.new(@repo).prepare
    refute s.exported_branch?
    assert s.dirty?
    assert_equal File.expand_path(@repo), s.root
  end
end

class OutputDirTest < Minitest::Test
  include Helpers

  NPM = '{"scripts":{"build":"node build.js"}}'

  def site(files) = Quickhost::Site.new(root: repo(files), config: config, fallback_name: "auto-boss")

  def test_capacitor_web_dir_comes_first
    s = site("package.json" => NPM, "capacitor.config.json" => '{"webDir":"./app-www/"}')
    assert_equal "app-www", s.output_dirs.first
    assert_includes s.output_dirs, "www"
  end

  def test_unsafe_capacitor_web_dir_ignored
    s = site("package.json" => NPM, "capacitor.config.json" => '{"webDir":"../etc; rm -rf /"}')
    assert_equal Quickhost::Site::OUTPUT_DIRS, s.output_dirs
  end

  # Runs the Dockerfile's "pick the output" step with sh, pointing /site at a temp folder.
  def pick_output(s, built)
    line = Quickhost::BuildContext.new(s).dockerfile.lines.find { |l| l.start_with?("RUN for d in") }
    Dir.mktmpdir do |work|
      out = File.join(work, "site")
      src = File.join(work, "src")
      built.each { |path, body| FileUtils.mkdir_p(File.dirname(File.join(src, path))); File.write(File.join(src, path), body) }
      ok = system("sh", "-c", line.delete_prefix("RUN ").gsub("/site", out), chdir: src, out: File::NULL, err: File::NULL)
      return [ok, ok ? Dir.glob("**/*", base: out).sort : []]
    end
  end

  def test_auto_boss_layout_serves_www
    s = site("package.json" => NPM, "capacitor.config.json" => '{"webDir":"www"}')
    ok, files = pick_output(s, "index.html" => "x", "www/index.html" => "x", "build.js" => "", "node_modules/a/b.js" => "")
    assert ok
    assert_equal ["index.html"], files
  end

  def test_falls_back_to_repo_root_without_node_modules
    s = site("package.json" => NPM)
    ok, files = pick_output(s, "index.html" => "x", "game.js" => "", "node_modules/a/b.js" => "")
    assert ok
    assert_equal ["game.js", "index.html"], files
  end

  def test_fails_when_no_index_anywhere
    s = site("package.json" => NPM)
    ok, = pick_output(s, "game.js" => "")
    refute ok
  end
end

class HubTest < Minitest::Test
  include Helpers

  TABLE = "\e[3;94mService\e[0m                     \e[3;94mHost\e[0m                                               \e[3;94mPath\e[0m  \e[3;94mTarget\e[0m              \e[3;94mState\e[0m    \e[3;94mTLS\e[0m  \n" \
          "\e[1;34mbluemap\e[0m                     \e[mmap.whittleadams.com\e[0m                               \e[m/\e[0m     \e[m192.168.0.253:8100\e[0m  \e[mrunning\e[0m  \e[myes\e[0m  \n" \
          "\e[1;34mproductivity_diary_api-web\e[0m  \e[mdiary.whittleadams.com,diary.louislab.duckdns.org\e[0m  \e[m/\e[0m     \e[m577d20c2eb61:3000\e[0m   \e[mrunning\e[0m  \e[myes\e[0m  \n" \
          "\e[1;34mqh-sites\e[0m                    \e[msites.whittleadams.com\e[0m                             \e[m/\e[0m     \e[mqh-sites-1:80\e[0m        \e[mrunning\e[0m  \e[myes\e[0m  \n" \
          "\e[1;34mqh-oaat\e[0m                     \e[moaat.whittleadams.com\e[0m                              \e[m/\e[0m     \e[mqh-oaat-1:80\e[0m         \e[mrunning\e[0m  \e[myes\e[0m  \n"

  FakeRoutes = Struct.new(:proxy_list)

  class OfflineHub < Quickhost::Hub
    PAGES = {
      "https://oaat.whittleadams.com/" => [200, %(<title>OAAT &amp; co</title><meta name="description" content="Read &lt;fast&gt;">)],
      "https://diary.whittleadams.com/" => [404, ""],
    }.freeze

    private

    def fetch(url, **) = PAGES.fetch(url, ["SocketError", ""])
  end

  def hub(**cfg) = OfflineHub.new(config: config(**cfg), deployer: nil, routes_from: FakeRoutes.new(TABLE), out: StringIO.new)

  def test_parse_routes_strips_colours_and_takes_first_host
    routes = Quickhost::Hub.parse_routes(TABLE)
    assert_equal %w[bluemap productivity_diary_api-web qh-sites qh-oaat], routes.map { _1[:service] }
    assert_equal "diary.whittleadams.com", routes[1][:host]
    assert_equal "running", routes[0][:state]
  end

  def test_entries_skip_hub_itself_and_hidden_sites
    entries = hub(hub_hide: ["map.whittleadams.com"]).entries
    assert_equal %w[diary.whittleadams.com oaat.whittleadams.com], entries.map(&:host)
    assert_equal %w[oaat.whittleadams.com], hub(hub_hide: "diary,map.whittleadams.com").entries.map(&:host)
  end

  def test_private_sites_stay_off_the_hub
    routes = Struct.new(:proxy_list, :sites).new(TABLE, [
      Quickhost::SiteInfo.new(name: "oaat", meta: Quickhost::Meta.new(host: "oaat.whittleadams.com", auth: "u:{SSHA}h"))
    ])
    hub = OfflineHub.new(config: config, deployer: nil, routes_from: routes, out: StringIO.new)
    assert_equal %w[diary.whittleadams.com map.whittleadams.com], hub.entries.map(&:host).sort
  end

  def test_hub_sites_overrides_wording
    sites = { "map" => { "title" => "Minecraft Map", "description" => "Live 3D map" },
              "qh-oaat" => { "description" => "" },
              "diary.whittleadams.com" => { "title" => "  " } }
    entries = hub(hub_sites: sites).entries.to_h { [_1.host, _1] }
    assert_equal "Minecraft Map", entries["map.whittleadams.com"].title
    assert_equal "Live 3D map", entries["map.whittleadams.com"].description
    assert_equal "OAAT & co", entries["oaat.whittleadams.com"].title
    assert_nil entries["oaat.whittleadams.com"].description, "empty description removes the site's own"
    assert_equal "Diary", entries["diary.whittleadams.com"].title, "blank title falls back"
  end

  def test_titles_status_and_escaping
    entries = hub.entries.to_h { [_1.host, _1] }
    oaat = entries["oaat.whittleadams.com"]
    assert_equal "OAAT & co", oaat.title
    assert_equal "Read <fast>", oaat.description
    assert entries["diary.whittleadams.com"].up?, "a 404 from an API still counts as up"
    refute entries["map.whittleadams.com"].up?
    assert_equal "Map", entries["map.whittleadams.com"].title

    html = hub.html(now: Time.utc(2026, 11, 10, 12))
    assert_includes html, "OAAT &amp; co"
    assert_includes html, "Read &lt;fast&gt;"
    refute_includes html, "sites.whittleadams.com\""
    assert_includes html, "3 sites · 2 up"
    assert_includes html, %(href="https://oaat.whittleadams.com")
  end
end
