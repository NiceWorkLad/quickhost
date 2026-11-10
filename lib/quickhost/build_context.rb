require "fileutils"
require "tmpdir"

module Quickhost
  # Writes a Docker build context (repo files + Dockerfile + nginx.conf) to a temp folder.
  class BuildContext
    SKIP = %w[.git node_modules .DS_Store].freeze

    attr_reader :dir

    def initialize(site)
      @site = site
    end

    def create
      @dir = Dir.mktmpdir("quickhost-ctx-")
      copy_repo(File.join(@dir, "src"))
      File.write(File.join(@dir, "Dockerfile"), dockerfile)
      File.write(File.join(@dir, "nginx.conf"), nginx_conf)
      @dir
    end

    def cleanup
      FileUtils.rm_rf(@dir) if @dir
    end

    def dockerfile
      if @site.build_command
        out = @site.options["dir"]
        pick = if out
                 "test -d #{shell_word(out)} || (echo 'Build output folder #{out} not found' >&2; exit 1); " \
                 "mkdir -p /site && cp -a #{shell_word(out)}/. /site/"
               else
                 # Try each likely output folder; as a last resort serve the repo root, for builds
                 # that write index.html in place (GitHub Pages style).
                 dirs = @site.output_dirs
                 "for d in #{dirs.map { |d| shell_word(d) }.join(' ')}; do " \
                 "if [ -f \"$d/index.html\" ]; then mkdir -p /site && cp -a \"$d\"/. /site/ && echo \"Serving $d/\" && break; fi; done; " \
                 "if [ ! -f /site/index.html ] && [ -f index.html ]; then mkdir -p /site && cp -a . /site/ && rm -rf /site/node_modules && echo 'Serving repo root'; fi; " \
                 "test -f /site/index.html || (echo 'Build finished but no index.html found in #{dirs.join(', ')} or the repo root. Set --dir.' >&2; exit 1)"
               end
        <<~DOCKER
          FROM #{@site.node_image} AS build
          WORKDIR /src
          COPY src/ ./
          RUN #{@site.build_command}
          RUN #{pick}

          FROM nginx:1.27-alpine
          COPY nginx.conf /etc/nginx/conf.d/default.conf
          COPY --from=build /site/ /usr/share/nginx/html/
        DOCKER
      else
        <<~DOCKER
          FROM nginx:1.27-alpine
          COPY nginx.conf /etc/nginx/conf.d/default.conf
          COPY src/#{@site.static_dir == '.' ? '' : "#{@site.static_dir}/"} /usr/share/nginx/html/
        DOCKER
      end
    end

    def nginx_conf
      fallback = @site.spa? ? "/index.html" : "=404"
      <<~NGINX
        server {
          listen 80;
          server_name _;
          root /usr/share/nginx/html;
          index index.html;

          gzip on;
          gzip_types text/plain text/css application/javascript application/json image/svg+xml;

          # kamal-proxy health check
          location = /up { access_log off; add_header Content-Type text/plain; return 200 "ok\\n"; }

          # Never serve dotfiles (.env, .quickhost.yml, ...)
          location ~ /\\.(?!well-known) { deny all; return 404; }

          location / {
            try_files $uri $uri/ $uri.html #{fallback};
          }

          error_page 404 /404.html;
          location = /404.html { internal; }
        }
      NGINX
    end

    private

    def copy_repo(dest)
      FileUtils.mkdir_p(dest)
      Dir.children(@site.root).each do |entry|
        next if SKIP.include?(entry)

        FileUtils.cp_r(File.join(@site.root, entry), dest, preserve: false)
      end
    end

    def shell_word(str)
      require "shellwords"
      Shellwords.escape(str)
    end
  end
end
