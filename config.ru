# frozen_string_literal: true

# The registry service's entry point. `bundle exec puma` runs it.
#
# Environment:
#   REGISTRY_BOX_URL                box's redeem route (required)
#   REGISTRY_GITHUB_APP_ID          GitHub App id (required)
#   REGISTRY_GITHUB_APP_KEY          the App's PEM private key (required, never logged)
#   REGISTRY_GITHUB_INSTALLATION_ID  the App's installation id (required)
#   REGISTRY_GITHUB_API_URL         override for tests (default https://api.github.com)
#   REGISTRY_REGISTRY_HOST          the registry to mint for (default ghcr.io)
#   PORT                            listen port (default 9292)
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "registry/authority"
require "registry/exchange"
require "registry/app"

def build_registry_app
  Registry::App.new(
    exchange: Registry::Exchange.new(
      box_url: ENV.fetch("REGISTRY_BOX_URL"),
      authority: Registry::Authority.new(
        private_pem: ENV["REGISTRY_GITHUB_APP_KEY"],
        app_id: ENV["REGISTRY_GITHUB_APP_ID"],
        installation_id: ENV["REGISTRY_GITHUB_INSTALLATION_ID"],
        api_url: ENV["REGISTRY_GITHUB_API_URL"]
      ),
      registry: ENV.fetch("REGISTRY_REGISTRY_HOST", "ghcr.io")
    ),
    logger: $stdout
  )
end

run build_registry_app
