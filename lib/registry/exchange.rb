# frozen_string_literal: true

module Registry
  # The exchange: a box-bound, purpose-bound capability in; a short-lived
  # pull-only dockerconfigjson out. Exactly one spend per capability, and the
  # credential is returned in the response body and nowhere else.
  #
  # ## The path, measured
  #
  #   1. the request is shaped before any network call. A pasted
  #      dockerconfigjson — the value an older runbook asks for — never
  #      reaches box as an opaque bearer;
  #   2. the capability is spent at box, through Registry::Box, naming the
  #      purpose and the box it is being redeemed FOR. Box refuses an expired,
  #      already-redeemed, wrong-purpose or wrong-box capability WITHOUT the
  #      registry service having to trust the caller to have checked, and
  #      every one of those refusals is passed through with box's own status
  #      and code;
  #   3. the receipt is re-checked HERE against the box the request named.
  #      This is belt and braces over box's own binding, and it is the half
  #      that makes the guarantee local: a box_id in the receipt that is not
  #      the box that asked is a refusal, not a subtlety;
  #   4. an installation token is minted from the App key, and it must arrive
  #      pull-only and still alive or the exchange refuses rather than handing
  #      over something that will fail at image-pull time in a voice nobody
  #      can attribute — the same failure the installer's preflight exists to
  #      prevent;
  #   5. the dockerconfigjson is returned. It is never logged, never stored,
  #      and never written anywhere by this service.
  #
  # ## What this service does not hold
  #
  # No registry password, no PAT, no operator secret. One GitHub App private
  # key that cannot be used against a registry directly (see
  # Registry::Authority for the argument). Box holds no registry material
  # either, which is why the exchange lives here and not behind box's redeem
  # route — option (b) in the report.
  class Exchange
    # The floor an installation token must still have on it. GitHub mints at
    # an hour; a token that arrives with less than this left is a credential
    # that dies mid-pull, and the honest answer is a refusal and a retry, not
    # a Secret that expires while pods are starting.
    MINIMUM_SECONDS = 60

    class Refusal < StandardError
      attr_reader :status, :code

      def initialize(status:, code:, message:)
        @status = status
        @code = code
        super(message)
      end
    end

    CAPABILITY_SHAPE = /\Acap_[0-9a-f]{64}\z/
    UUID_SHAPE = /\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

    attr_reader :box_url, :authority

    # `clock` is injected so the suite can prove an expiry refusal without
    # sleeping for an hour. `box_opener` replaces Net::HTTP entirely, so the
    # suite drives real HTTP request construction (real headers, real body,
    # real URL) against a stub instead of asserting that a mock was called.
    def initialize(box_url:, authority:, clock: nil, registry: nil, box_opener: nil)
      @box_url = box_url
      @authority = authority
      @clock = clock || -> { Time.now }
      @registry = registry
      @box_opener = box_opener
    end

    # `capability` is the raw bearer token, `box_id` names the box it is being
    # spent for. Both are required and both are shaped before the network.
    def call(capability:, box_id:)
      now = @clock.call

      if capability.to_s.strip.empty?
        raise Refusal.new(status: 400, code: "capability_required",
          message: "a registry.pull capability is required")
      end
      unless capability.to_s.match?(CAPABILITY_SHAPE)
        raise Refusal.new(status: 400, code: "capability_malformed",
          message: "that is not a minted capability — a dockerconfigjson belongs in the OLD runbook: it is redeemed, not pasted")
      end
      if box_id.to_s.strip.empty?
        raise Refusal.new(status: 400, code: "box_id_required",
          message: "box_id is required: a registry.pull capability is bound to exactly one box")
      end
      unless box_id.to_s.match?(UUID_SHAPE)
        raise Refusal.new(status: 400, code: "box_id_malformed", message: "box_id must be a UUID")
      end

      # Spend the capability at box, naming what the exchange is FOR. Box
      # refuses an expired, already-redeemed, wrong-purpose or wrong-box
      # capability; each of those arrives here as a Box::Refusal carrying box's
      # own status and code, and is passed through unchanged.
      receipt = spend(capability, box_id)

      # The receipt is re-checked against the box that asked. Box already
      # enforces this (for_box:), and the local re-check is what makes the
      # guarantee true even if a caller ever reached the exchange by another
      # route.
      unless receipt["purpose"].to_s == "registry.pull"
        raise Refusal.new(status: 403, code: "capability_wrong_purpose",
          message: "box's receipt is for purpose '#{receipt['purpose']}', not registry.pull")
      end
      unless receipt["box_id"].to_s == box_id
        raise Refusal.new(status: 403, code: "capability_wrong_box",
          message: "box's receipt is for another box, not this one")
      end
      # A receipt with no expiry is a shape this exchange does not consume:
      # box always renders one, and the credential's own TTL is what actually
      # bounds the exchange, so a missing one is a defect rather than a bypass.
      raw_expiry = receipt["expires_at"].to_s
      if raw_expiry.empty?
        raise Refusal.new(status: 502, code: "bad_upstream",
          message: "box's receipt carries no expires_at")
      elsif parse_time(raw_expiry).nil?
        raise Refusal.new(status: 502, code: "bad_upstream",
          message: "box's receipt carries an unparseable expires_at")
      end

      minted = @authority.installation_token
      Minted.new(
        token: minted.token,
        expires_at: minted.expires_at,
        permissions: minted.permissions,
        registry: @registry
      ).then { |credential| guard_credential(credential, now) }
    end

    private

    def spend(capability, box_id)
      Registry::Box.new(url: @box_url, token: capability, opener: @box_opener).redeem(box_id: box_id)
    rescue Registry::Box::Refusal => e
      raise Refusal.new(status: e.status, code: e.code, message: e.message)
    rescue Registry::Box::Unreachable => e
      raise Refusal.new(status: 502, code: "box_unreachable", message: e.message)
    end

    # A credential that is not pull-only, or that is already dead, is refused.
    # Both are the failure the installer's preflight exists to prevent: write
    # the Secret, schedule the pods, and fail at image-pull time in a voice
    # nobody can attribute.
    def guard_credential(credential, now)
      raise Refusal.new(status: 502, code: "credential_expired",
        message: "the minted credential is already expired — nothing to hand over") if credential.expired?(now: now)

      unless credential.usable?(now: now)
        raise Refusal.new(status: 502, code: "credential_unusable",
          message: "the minted credential carries no usable lifetime")
      end
      if credential.seconds_remaining(now: now) < MINIMUM_SECONDS
        raise Refusal.new(status: 503, code: "credential_too_short_lived",
          message: "the minted credential has less than #{MINIMUM_SECONDS}s of life left — retry the exchange")
      end
      unless credential.pull_only?
        raise Refusal.new(status: 502, code: "credential_not_pull_only",
          message: "the minted credential is not pull-only — the installation's permissions must be read:packages and nothing else")
      end

      credential
    end

    def parse_time(value)
      Time.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
