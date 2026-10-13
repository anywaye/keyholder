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
# `$LOAD_PATH` is built from the working directory, not `__dir__`: a config.ru
# loaded by `Rack::Builder.new_from_string` is `eval`'d from a string, where
# `__dir__` answers nothing useful. Puma and rackup both inherit the directory
# they were started in, which is this repository's root and where `lib/` is.
$LOAD_PATH.unshift File.join(Dir.pwd, "lib")

require "registry/authority"
require "registry/exchange"
require "registry/app"

def build_registry_app
  # The App key arrives as a mounted file (a Kubernetes projected secret, the
  # form an operator should use) or, failing that, as the PEM itself in the
  # environment. A file is preferred because a value in an environment is
  # readable by anything that can read /proc for the process; a mounted file
  # is not, and the content is only ever in this process's memory.
  key_pem = if (key_file = ENV["REGISTRY_GITHUB_APP_KEY_FILE"].to_s) && !key_file.empty?
    File.read(key_file)
  else
    ENV["REGISTRY_GITHUB_APP_KEY"]
  end
  Registry::App.new(
    exchange: Registry::Exchange.new(
      box_url: ENV.fetch("REGISTRY_BOX_URL"),
      authority: Registry::Authority.new(
        private_pem: key_pem,
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
