module Quickhost
  VERSION = "0.3.0".freeze
  class Error < StandardError; end
end

require_relative "quickhost/config"
require_relative "quickhost/site"
require_relative "quickhost/build_context"
require_relative "quickhost/remote"
require_relative "quickhost/source"
require_relative "quickhost/deployer"
require_relative "quickhost/hub"
require_relative "quickhost/sync"
require_relative "quickhost/cli"
