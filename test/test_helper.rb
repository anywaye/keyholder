# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# The exchange's own suite. Everything it asserts is asserted against real
# objects: the app is driven through Rack with a real `Rack::Request`, the
# capability is spent through `Registry::Box` with a stub NET/HTTP opener that
# speaks real HTTP responses, and the credential is minted from a real RSA key
# through the same `Authority` code path production uses. The only thing faked
# is the two networks that must not be dialed in a test — GitHub, and a live
# box — and each is faked at its wire boundary so the code under test is the
# code that ships.
require "minitest/autorun"
require "rack/test"
require "openssl"

# ONLY the entry point the production process loads. Every dependency is
# pulled in transitively by that one file, so a missing `require` — the bug
# the end-to-end run found, where `Registry::Box` was reachable from the
# suite but not from the app — fails here rather than on a customer's box.
require "registry/app"

module RegistryTest
  # A real RSA key, so Authority's parsing, validation and RS256 signing are
  # the shipped ones. 2048 bits is GitHub's floor for App keys.
  APP_KEY = OpenSSL::PKey::RSA.generate(2048).to_pem

  BOX_ID = "11111111-2222-3333-4444-555555555555"
  OTHER_BOX_ID = "88888887-7777-6666-5555-444444444444"
  BOX_URL = "https://box.svc.cafaye.test"

  # A capability of the minted shape. This is a LABEL, not a credential —
  # nothing in the test suite can mint a real one, because minting is an
  # account member's flow at box (CapabilitiesController#create) and not this
  # service's. The report's measurement mints a real one.
  CAPABILITY = "cap_#{"a" * 64}"
  OTHER_CAPABILITY = "cap_#{"b" * 64}"

  # A stub at Net::HTTP's boundary. Box receives the exact request the
  # production client builds — same path, same bearer, same purpose/box body —
  # and answers with the exact status and body a real box would.
  class FakeBoxGateway
    attr_reader :requests

    def initialize(responder)
      @responder = responder
      @requests = []
    end

    def new(host, port)
      self
    end

    # Net::HTTP's own constructor surface, because `Box` builds an
    # `Net::HTTP` and calls `.start` on whatever the opener returns.
    def use_ssl=(_value); end
    def open_timeout=(_value); end
    def read_timeout=(_value); end

    def start
      yield self
    end

    def request(request)
      @requests << {
        path: request.path,
        method: request.method,
        authorization: request["Authorization"],
        body: request.body,
        content_type: request["Content-Type"]
      }
      @responder.call
    end
  end

  # The authority the exchange consults, driven by a real RSA key. `responder`
  # answers the GitHub installation-token request.
  class FakeAuthority < Registry::Authority
    attr_reader :github_requests

    def initialize(responder)
      @responder = responder
      @github_requests = []
      super(
        private_pem: APP_KEY,
        app_id: "123456",
        installation_id: "987654",
        api_url: "https://api.github.test",
        opener: nil
      )
    end

    private

    def http_post(url, headers:, body:)
      @github_requests << { url: url, headers: headers }
      JSON.parse(@responder.call.body)
    end
  end

  # A JSON/HTTP response, because `Box` and `Authority` both check
  # `is_a?(Net::HTTPSuccess)` / `Net::HTTPClientError`.
  def json_response(status, body)
    klass = Net::HTTPResponse::CODE_TO_OBJ.fetch(status.to_s)
    response = klass.new("1.1", status.to_s, "")
    response.instance_variable_set(:@body, body)
    def response.body
      @body
    end
    response
  end

  # Box's own redemption answers, spelled exactly as the renderers spell them
  # (app/controllers/capabilities_controller.rb).
  def box_receipt(purpose: "registry.pull", box_id: BOX_ID, expires_at: nil)
    JSON.generate(
      capability: {
        purpose: purpose,
        box_id: box_id,
        account_id: "99999999-8888-7777-6666-555555555555",
        expires_at: expires_at || Time.now.utc.iso8601
      }
    )
  end

  # GitHub's own installation-token answer.
  def github_installation_token(expires_at: nil, permissions: { "packages" => "read" })
    JSON.generate(
      token: "ghs_realtokenvalue",
      expires_at: (expires_at || Time.now + 3600).utc.iso8601,
      permissions: permissions
    )
  end

  # The default authority: a live one-hour, read:packages installation token.
  def read_only_authority(expires_at: nil, permissions: { "packages" => "read" })
    FakeAuthority.new(-> { json_response(201, github_installation_token(expires_at: expires_at, permissions: permissions)) })
  end

  def stub_box(&responder)
    FakeBoxGateway.new(responder)
  end

  # An exchange wired to a stub box. The default responder is a successful
  # redemption; pass `responder:` to plant box's answer.
  def exchange(authority: nil, responder: nil, clock: nil)
    args = {
      box_url: BOX_URL,
      authority: authority || read_only_authority,
      box_opener: RegistryTest::FakeBoxGateway.new(responder || -> { json_response(200, box_receipt) })
    }
    args[:clock] = clock if clock
    Registry::Exchange.new(**args)
  end

  # The whole path with the defaults for the guard tests that plant only the
  # capability and the box id.
  def exchange_call(capability:, box_id:, **opts)
    exchange(**opts).call(capability: capability, box_id: box_id)
  end
end
