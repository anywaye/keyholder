# frozen_string_literal: true

require "test_helper"

# The four refusals the brief names, plus the shape that makes them real:
# a capability is spent exactly once, and every box refusal is answered with
# box's own status and code rather than a registry-shaped guess.
class ExchangeTest < Minitest::Test
  include RegistryTest
  # --- 1. an expired receipt is refused ------------------------------------
  #
  # Box answers its `capability_expired` renderer (410, code
  # `capability_expired`) — app/controllers/capabilities_controller.rb maps
  # "capability expired" there. The exchange passes it through unchanged, so
  # the operator hears the same refusal at the registry door that they would
  # have heard at box's.
  def test_an_expired_capability_is_refused_with_boxs_own_refusal
    error = assert_raises(Registry::Exchange::Refusal) do
      exchange(responder: -> { json_response(410, JSON.generate(error: { code: "capability_expired", message: "capability has expired" })) })
        .call(capability: CAPABILITY, box_id: BOX_ID)
    end

    assert_equal 410, error.status
    assert_equal "capability_expired", error.code
    # And nothing was minted: a refusal must not reach the authority at all.
    assert_equal 0, exchange.authority.github_requests.size
  end

  # --- 2. a receipt for another box is refused ------------------------------
  #
  # Box answers its `capability_wrong_box` renderer (403). The exchange passes
  # it through, and — belt and braces — re-checks the receipt's box against
  # the box the request named even when box's own answer is well-formed: a
  # registry exchange that mints a credential for a box other than the one
  # asking is the leak this whole design exists to prevent.
  def test_a_capability_bound_to_another_box_is_refused
    error = assert_raises(Registry::Exchange::Refusal) do
      exchange(responder: -> { json_response(403, JSON.generate(error: { code: "capability_wrong_box", message: "capability is bound to a different box" })) })
        .call(capability: CAPABILITY, box_id: BOX_ID)
    end

    assert_equal 403, error.status
    assert_equal "capability_wrong_box", error.code
  end

  def test_a_receipt_for_another_box_is_refused_locally_even_if_box_said_yes
    # The synthetic case: box redeems (200) but renders a receipt naming a
    # different box. The exchange refuses on its own re-check.
    error = assert_raises(Registry::Exchange::Refusal) do
      exchange(responder: -> { json_response(200, box_receipt(box_id: OTHER_BOX_ID)) })
        .call(capability: CAPABILITY, box_id: BOX_ID)
    end

    assert_equal 403, error.status
    assert_equal "capability_wrong_box", error.code
  end

  # --- 3. the credential it returns is pull-only and expires ----------------
  def test_a_redeemed_capability_buys_a_short_lived_pull_only_credential
    expires_at = Time.now.utc + 3600
    authority = read_only_authority(expires_at: expires_at)
    credential = exchange(authority: authority, responder: -> { json_response(200, box_receipt) })
      .call(capability: CAPABILITY, box_id: BOX_ID)

    assert credential.pull_only?, "the minted credential must be pull-only"
    assert credential.expires_at <= expires_at, "the credential must not outlive GitHub's own expiry"
    assert_in_delta 3600, credential.seconds_remaining, 5
    refute credential.expired?, "the credential must be alive when it is handed over"
    assert_equal({ "packages" => "read" }, credential.permissions)
    # The dockerconfigjson is the real, decodable, encoded thing — the value
    # that goes into the Secret.
    decoded = JSON.parse(Base64.strict_decode64(credential.encoded_dockerconfigjson))
    assert_equal "ghcr.io", decoded.fetch("auths").keys.first
    assert_equal "x-access-token", decoded.fetch("auths").fetch("ghcr.io").fetch("username")
  end

  def test_a_credential_that_can_push_is_refused
    # read:packages AND contents:write is not a pull-only credential. The
    # exchange refuses rather than handing over something that could push.
    authority = read_only_authority(permissions: { "packages" => "read", "contents" => "write" })
    error = assert_raises(Registry::Exchange::Refusal) do
      exchange(authority: authority, responder: -> { json_response(200, box_receipt) })
        .call(capability: CAPABILITY, box_id: BOX_ID)
    end

    assert_equal 502, error.status
    assert_equal "credential_not_pull_only", error.code
  end

  def test_a_credential_that_is_already_expired_is_refused
    authority = read_only_authority(expires_at: Time.now.utc - 1)
    error = assert_raises(Registry::Exchange::Refusal) do
      exchange(authority: authority, responder: -> { json_response(200, box_receipt) })
        .call(capability: CAPABILITY, box_id: BOX_ID)
    end

    assert_equal 502, error.status
    assert_equal "credential_expired", error.code
  end

  def test_a_credential_with_almost_no_lifetime_left_is_refused
    # 30 seconds is enough to start a pull and not enough to finish one.
    authority = read_only_authority(expires_at: Time.now.utc + 30)
    error = assert_raises(Registry::Exchange::Refusal) do
      exchange(authority: authority, responder: -> { json_response(200, box_receipt) })
        .call(capability: CAPABILITY, box_id: BOX_ID)
    end

    assert_equal 503, error.status
    assert_equal "credential_too_short_lived", error.code
  end

  # --- the capability is spent exactly once, and only when it is good -------
  def test_the_capability_is_presented_to_box_once_naming_purpose_and_box
    gateway = stub_box { json_response(200, box_receipt) }
    authority = read_only_authority
    Registry::Exchange.new(
      box_url: BOX_URL, authority: authority, box_opener: gateway
    ).call(capability: CAPABILITY, box_id: BOX_ID)

    assert_equal 1, gateway.requests.size
    request = gateway.requests.first
    assert_equal "/v1/capabilities/redeem", request.fetch(:path)
    assert_equal "Bearer #{CAPABILITY}", request.fetch(:authorization)
    assert_equal "application/json", request.fetch(:content_type)
    body = JSON.parse(request.fetch(:body))
    assert_equal "registry.pull", body.fetch("purpose")
    assert_equal BOX_ID, body.fetch("box_id")
  end

  def test_a_refusal_never_reaches_the_authority
    authority = read_only_authority
    [
      [410, "capability_expired"],
      [403, "capability_wrong_box"],
      [403, "capability_wrong_purpose"],
      [409, "capability_redeemed"],
      [404, "not_found"]
    ].each do |status, code|
      ex = exchange(authority: authority, responder: -> { json_response(status, JSON.generate(error: { code: code, message: "no" })) })
      assert_raises(Registry::Exchange::Refusal) { ex.call(capability: CAPABILITY, box_id: BOX_ID) }
      assert_equal 0, authority.github_requests.size,
        "a #{status} refusal from box must not mint a credential"
    end
  end

  # --- the request is shaped before any network call ------------------------
  #
  # The installer's old failure mode: an operator following an older runbook
  # pastes a dockerconfigjson where a capability belongs. That must never
  # reach box as an opaque bearer.
  def test_a_pasted_dockerconfigjson_is_refused_before_the_network
    pasted = Base64.strict_encode64(JSON.generate(auths: { "ghcr.io" => { auth: "ZmFrZQ==" } }))
    authority = read_only_authority
    error = assert_raises(Registry::Exchange::Refusal) do
      exchange(authority: authority, responder: -> { json_response(200, box_receipt) })
        .call(capability: pasted, box_id: BOX_ID)
    end

    assert_equal 400, error.status
    assert_equal "capability_malformed", error.code
    assert_match(/dockerconfigjson/, error.message)
    assert_equal 0, authority.github_requests.size
  end

  def test_a_capability_and_a_box_id_are_both_required
    error = assert_raises(Registry::Exchange::Refusal) do
      exchange_call(capability: nil, box_id: BOX_ID)
    end
    assert_equal "capability_required", error.code

    error = assert_raises(Registry::Exchange::Refusal) do
      exchange_call(capability: CAPABILITY, box_id: nil)
    end
    assert_equal "box_id_required", error.code

    error = assert_raises(Registry::Exchange::Refusal) do
      exchange_call(capability: CAPABILITY, box_id: "not-a-uuid")
    end
    assert_equal "box_id_malformed", error.code
  end

  # --- the box being unreachable is a refusal, not a crash ------------------
  def test_an_unreachable_box_is_a_refusal
    gateway = RegistryTest::FakeBoxGateway.new(-> { raise(Errno::ECONNREFUSED) })
    error = assert_raises(Registry::Exchange::Refusal) do
      Registry::Exchange.new(
        box_url: BOX_URL, authority: read_only_authority, box_opener: gateway
      ).call(capability: CAPABILITY, box_id: BOX_ID)
    end

    assert_equal 502, error.status
    assert_equal "box_unreachable", error.code
  end
end
