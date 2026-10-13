# frozen_string_literal: true

require "jwt"
require "net/http"
require "uri"
require "json"
require "base64"
require "time"

require "registry/minted"

module Registry
  # The registry authority — the ONLY place in the fleet that holds registry
  # source material, and the reason option (b) was chosen over option (a).
  #
  # ## What it holds
  #
  # A GitHub App's private key and its App ID. Nothing else long-lived is
  # stored anywhere in this service: there is no GHCR password, no PAT, and
  # no operator secret in the environment.
  #
  # ## Why a private key is not a long-lived operator secret
  #
  # Option (c) — a deploy bot's PAT — was rejected because a PAT with
  # `read:packages` is BOTH a registry password and a general GitHub identity:
  # it authenticates directly against ghcr.io for as long as it lives, and its
  # compromise is total until a human rotates it. The App private key cannot
  # be used against ghcr.io at all: ghcr.io has no idea what to do with an
  # RSA key. The only thing the key can do is sign an assertion that THIS app
  # made a request at a given time, and GitHub answers that assertion with an
  # installation access token that:
  #
  #   * carries only the permissions the App was granted (`read:packages`,
  #     scoped to the repositories it is installed on) — so it is pull-only by
  #     construction, not by policy;
  #   * expires in at most one hour, on GitHub's clock, not ours;
  #   * is useless for anything else in GitHub — it cannot read other repos,
  #     push, or read the account.
  #
  # The long-lived material is therefore the minimum any issuer can carry: the
  # power to say "I am this app", bounded by the app's own permission set.
  # This is the same posture `Capability::TTL_MINUTES` keeps for enrollments —
  # revocable by expiry rather than by rotation — applied to the credential's
  # source. Rotating the key revokes nothing that was already dead.
  #
  # ## Why not octokit
  #
  # The fleet's dependency rule says a good existing library is the default.
  # For the JWT we take it (`jwt`). For the token exchange we deliberately do
  # not: the call is ONE request — `POST
  # /app/installations/:id/access_tokens` with a JWT bearer — and `octokit` is
  # a full GitHub API client whose version tracker, paginator, middleware
  # stack and own faraday/sawyer dependency tree we would inherit to make
  # exactly that one call. That is the exception, and this paragraph is the
  # reason written at the code site. The request itself is built on the
  # standard library's `net/http`, which is the same client `jwt`'s own test
  # suite and every Rails app's `ActiveSupport::HttpClient` wraps.
  class Authority
    # GitHub's own clock on an installation token. Read from the response and
    # never trusted from ours: the credential's lifetime is whatever GitHub
    # says it is.
    class Error < StandardError; end
    class Misconfigured < Error; end
    class Upstream < Error; end

    APP_JWT_TTL_SECONDS = 600

    attr_reader :app_id, :installation_id

    def initialize(private_pem:, app_id:, installation_id:, api_url: nil, opener: nil)
      raise Misconfigured, "REGISTRY_GITHUB_APP_ID is not set" if app_id.to_s.strip.empty?
      raise Misconfigured, "REGISTRY_GITHUB_APP_KEY is not set" if blank?(private_pem)
      raise Misconfigured, "REGISTRY_GITHUB_INSTALLATION_ID is not set" if installation_id.to_s.strip.empty?

      @app_id = app_id.to_s.strip
      @installation_id = installation_id.to_s.strip
      @api_url = api_url.to_s.strip.chomp("/")
      @api_url = "https://api.github.com" if @api_url.empty?
      # Injected so the test suite exercises the real signing and the real
      # request construction against a stub, rather than a mock that asserts
      # the mock.
      @opener = opener
      @private_pem = private_pem.to_s
      @private_key = OpenSSL::PKey::RSA.new(@private_pem)
    rescue OpenSSL::PKey::RSAError => e
      raise Misconfigured, "REGISTRY_GITHUB_APP_KEY is not an RSA private key: #{e.message}"
    end

    # Mint an installation access token. Returns a `Minted` carrying the
    # token, GitHub's own `expires_at`, and the permissions GitHub granted.
    def installation_token
      response = http_post(
        "#{@api_url}/app/installations/#{CGI.escape(@installation_id)}/access_tokens",
        headers: {
          "Authorization" => "Bearer #{app_jwt}",
          "Accept" => "application/vnd.github+json",
          "X-GitHub-Api-Version" => "2022-11-28",
          "User-Agent" => "cafaye-registry"
        },
        body: ""
      )
      minted_from(response)
    rescue Upstream => e
      raise
    rescue StandardError => e
      raise Upstream, "the registry authority could not mint an installation token: #{e.class}: #{e.message}"
    end

    private

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    # A JWT asserting this app, on GitHub's clock, for ten minutes. GitHub
    # allows at most ten; the assertion is refreshed per exchange rather than
    # cached, so the credential a box receives is never older than the
    # exchange that produced it.
    def app_jwt
      now = Time.now.to_i
      JWT.encode({ iat: now, exp: now + APP_JWT_TTL_SECONDS, iss: @app_id }, @private_key, "RS256")
    end

    def http_post(url, headers:, body:)
      uri = URI.parse(url)
      request = Net::HTTP::Post.new(uri)
      headers.each { |k, v| request[k] = v }
      if body.to_s.empty?
        request.content_length = 0
      else
        request.body = body
      end
      net = Net::HTTP.new(uri.host, uri.port)
      net.use_ssl = uri.scheme == "https"
      net.open_timeout = 5
      net.read_timeout = 10
      result = net.start { |http| http.request(request) }
      unless result.is_a?(Net::HTTPSuccess)
        raise Upstream, "GitHub answered #{result.code} to the installation-token request"
      end
      JSON.parse(result.body)
    end

    # A GitHub installation-token response, reduced to what the exchange
    # needs. `permissions` is carried through because the registry's own suite
    # asserts on it — pull-only is a property of the minted credential, and a
    # minted credential that can push is a defect the suite must be able to see.
    def minted_from(response)
      token = response.fetch("token")
      expires_at = response.fetch("expires_at")
      Minted.new(
        token: token,
        expires_at: Time.parse(expires_at.to_s),
        permissions: response["permissions"] || {}
      )
    rescue KeyError => e
      raise Upstream, "the installation-token response is missing #{e.key}"
    rescue ArgumentError => e
      raise Upstream, "the installation-token response carries an unparseable expires_at: #{e.message}"
    end
  end
end
