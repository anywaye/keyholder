# frozen_string_literal: true

require "test_helper"

# The fourth refusal the brief names: a dockerconfigjson written is never
# echoed. The assertion is made against every path a value can leak through —
# the service's log, the exception, the interpolated message — not just the
# obvious one.
class CredentialSafetyTest < Minitest::Test
  include RegistryTest
  include Rack::Test::Methods

  def setup
    @sink = StringIO.new
  end

  # The redacted form carries everything an operator needs and nothing a
  # registry could be handed.
  def test_the_credential_renders_redacted_anywhere_it_is_interpolated
    credential = build

    refute_match(/ghs_/, credential.inspect, "inspect must not carry the credential")
    refute_match(/ghs_/, credential.to_s, "to_s must not carry the credential")
    refute_match(/ghs_/, credential.to_s, "interpolation must not carry the credential")
    refute_match(/ghs_/, "note: #{credential}", "a log-line interpolation must not carry the credential")
    # The redacted form still says WHAT was minted.
    assert_match(/ghcr\.io/, credential.redacted)
    assert_match(/pull_only=true/, credential.redacted)
    assert_match(/expires_at=/, credential.redacted)
  end

  # The log line the service actually writes.
  def test_the_app_logs_the_outcome_and_never_the_credential
    header "Authorization", "Bearer #{CAPABILITY}"
    post "/v1/registry-credentials", JSON.generate(box_id: BOX_ID), "CONTENT_TYPE" => "application/json"

    assert_equal 200, last_response.status
    log = @sink.string
    assert_match(/registry\.credential_exchange/, log, "the outcome is logged")
    assert_match(/"status":200/, log)

    # THE assertion: the credential is not in the log, in any form.
    refute_match(/ghs_/, log, "the log must not echo the credential")
    refute_match(/dockerconfigjson/, log, "the log must not echo the dockerconfigjson")
    refute_match(/x-access-token/, log, "the log must not echo the username")
    refute_match(/eyJhdXRocyI/, log, "the log must not echo the encoded dockerconfigjson")
    # The capability is not echoed either.
    refute_match(/#{CAPABILITY}/, log, "the log must not echo the capability")
  end

  # The refusal path: the exchange answers box's own refusal, and the log
  # names it without carrying anything either side of it.
  def test_a_refusal_is_logged_without_the_credential
    @app = Registry::App.new(
      exchange: Registry::Exchange.new(
        box_url: BOX_URL,
        authority: read_only_authority,
        box_opener: RegistryTest::FakeBoxGateway.new(
          -> { json_response(410, JSON.generate(error: { code: "capability_expired", message: "capability has expired" })) }
        )
      ),
      logger: @sink
    )
    header "Authorization", "Bearer #{CAPABILITY}"
    post "/v1/registry-credentials", JSON.generate(box_id: BOX_ID), "CONTENT_TYPE" => "application/json"

    assert_equal 410, last_response.status, "box's own refusal is the answer, unchanged"
    assert_equal "capability_expired", JSON.parse(last_response.body).dig("error", "code")

    log = @sink.string
    assert_match(/capability_expired/, log, "the refusal is named")
    refute_match(/ghs_/, log)
    refute_match(/#{CAPABILITY}/, log, "the log must not echo the capability on the refusal path")
  end

  # The response body DOES carry the credential — that is the product — and it
  # is the only place in the service that it appears.
  def test_the_response_carries_the_credential_and_its_lifetime
    header "Authorization", "Bearer #{CAPABILITY}"
    post "/v1/registry-credentials", JSON.generate(box_id: BOX_ID), "CONTENT_TYPE" => "application/json"

    body = JSON.parse(last_response.body)
    assert body.key?("dockerconfigjson"), "the product is the dockerconfigjson"
    assert body["expires_at"], "and its lifetime"
    assert body["seconds_remaining"].to_i > 0
    # It decodes to a real ghcr.io auth entry.
    decoded = JSON.parse(Base64.strict_decode64(body.fetch("dockerconfigjson")))
    assert_equal "ghcr.io", decoded.fetch("auths").keys.first
    assert_equal "ghs_realtokenvalue", decoded.fetch("auths").fetch("ghcr.io").fetch("password")
  end

  # The route shape: a capability in a URL path would land in access logs, so
  # it goes in the bearer, and a route nobody declared is a 404.
  def test_an_unknown_route_is_a_404_and_health_is_a_200
    get "/healthz"
    assert_equal 200, last_response.status

    get "/v1/capabilities/#{CAPABILITY}/registry-credential"
    assert_equal 404, last_response.status, "the capability never travels in a URL path"
  end

  # A request with no bearer or no body is refused by shape, not by a 500.
  def test_a_request_without_the_capability_is_refused
    post "/v1/registry-credentials", JSON.generate(box_id: BOX_ID), "CONTENT_TYPE" => "application/json"
    assert_equal 400, last_response.status
    assert_equal "capability_required", JSON.parse(last_response.body).dig("error", "code")

    header "Authorization", "Bearer #{CAPABILITY}"
    post "/v1/registry-credentials", "not json", "CONTENT_TYPE" => "application/json"
    assert_equal 400, last_response.status
    assert_equal "malformed_body", JSON.parse(last_response.body).dig("error", "code")
  end

  # The house style, borrowed from the SECURITY.md idiom: no line of the source
  # writes the credential anywhere. A bare `puts`/`print`/`STDOUT` is the way a
  # value reaches a log, so the files that hold it are checked for one.
  # `@logger.puts` is a call on the injected log and is how the outcome is
  # written — the method, not a leaked value, so it is the form that must stay.
  def test_no_source_file_writes_the_credential_to_stdout
    Dir.glob(File.expand_path("../lib/**/*.rb", __dir__)).each do |file|
      source = File.read(file)
      refute_match(/^\s*puts\b/, source,
        "#{file} writes to stdout — a log line is the one place a secret is copied")
      refute_match(/^\s*print\b/, source, "#{file} writes to stdout")
      refute_match(/^\s*STDOUT\b/, source, "#{file} reaches for stdout directly")
    end
  end

  private

  # Rack::Test::Methods calls this. Built once per test, in-process, so the
  # HTTP surface is exercised as it ships rather than through a mock.
  def app
    @app ||= Registry::App.new(exchange: exchange, logger: @sink)
  end

  def build(expires_at: nil)
    Registry::Minted.new(
      token: "ghs_realtokenvalue",
      expires_at: expires_at || (Time.now + 3600),
      permissions: { "packages" => "read" }
    )
  end
end
