require "net/http"
require "openssl"
require "timeout"

module Quickhost
  # Fetches a page the way a visitor would, to see whether a site answers.
  module Probe
    TIMEOUT = 6

    module_function

    # → [status, body]. status is the HTTP code, or an error name like "SocketError".
    def get(url, redirects: 3)
      uri = URI(url)
      res = Timeout.timeout(TIMEOUT * 2) do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
          http.get(uri.request_uri, "User-Agent" => "quickhost", "Accept" => "text/html")
        end
      end
      if res.is_a?(Net::HTTPRedirection) && redirects.positive? && res["location"]
        return get(URI.join(url, res["location"]).to_s, redirects: redirects - 1)
      end
      [res.code.to_i, res.body.to_s.byteslice(0, 2_000_000).force_encoding("UTF-8").scrub]
    rescue StandardError, Timeout::Error => e
      [e.class.name.split("::").last, ""]
    end
  end
end
