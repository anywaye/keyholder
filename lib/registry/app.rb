# frozen_string_literal: true

require "json"

module Registry
  # The HTTP surface: one exchange route and a health check. Nothing else.
  #
  # ## The credential never touches a log
  #
  # The response body is written once, by Rack, to the socket. This service's
  # own logger records the request's OUTCOME — status, box, seconds of life,
  # whether the credential was pull-only — and never the body. `Minted#inspect`
  # is overridden to its redacted form so that even a stack trace or an
  # interpolated value that happens to carry the credential prints its shape
  # and not its secret; the suite asserts all three paths.
  #
  # ## Route shape, and the one that was rejected
  #
  # `POST /v1/registry-credentials` with the capability in the Authorization
  # bearer and `box_id` in the body. The report's suggested
  # `POST /v1/capabilities/:token/registry-credential` puts the credential in
  # a URL path — a path is logged by every proxy in front of this service, is
  # kept in access logs by Rack's own default logger, and ends up in browser
  # histories and crash reporters. A bearer header is how the fleet already
  # presents a capability (box's redeem route), so the same idiom here is both
  # the safer and the more consistent choice.
  class App
    def initialize(exchange:, logger: $stdout)
      @exchange = exchange
      @logger = logger
    end

    def call(env)
      request = Rack::Request.new(env)
      case [request.request_method, request.path_info]
      when ["GET", "/healthz"], ["GET", "/health"]
        [200, { "content-type" => "application/json" }, [JSON.generate({ status: "ok" })]]
      when ["POST", "/v1/registry-credentials"]
        exchange(request)
      else
        not_found
      end
    end

    private

    def exchange(request)
      capability = bearer(request)
      box_id = nil
      begin
        body = request.body.read
        box_id = JSON.parse(body.to_s)["box_id"] unless body.to_s.strip.empty?
      rescue JSON::ParserError
        return refusal(400, "malformed_body", "the request body is not JSON")
      end

      credential = @exchange.call(capability: capability, box_id: box_id)

      # The credential's shape is what gets logged, never its value: the
      # redacted form carries everything an operator needs to confirm the
      # exchange worked, and nothing a registry could be handed.
      log(status: 200, box_id: box_id, note: credential.redacted)
      [200, { "content-type" => "application/json" },
        [JSON.generate(
          registry: credential.registry,
          expires_at: credential.expires_at.utc.iso8601,
          seconds_remaining: credential.seconds_remaining,
          dockerconfigjson: credential.encoded_dockerconfigjson
        )]]
    rescue Exchange::Refusal => e
      log(status: e.status, box_id: box_id, note: "#{e.code}: #{e.message}")
      refusal(e.status, e.code, e.message)
    rescue Registry::Authority::Error => e
      # An upstream failure is not the caller's fault and is not a secret:
      # the request is refused with a 502 and the capability stays spent,
      # exactly as a failed image pull would be.
      log(status: 502, box_id: box_id, note: "authority: #{e.class}")
      refusal(502, "authority_error", e.message)
    rescue StandardError => e
      log(status: 500, box_id: box_id, note: "unhandled: #{e.class}")
      refusal(500, "internal_error", "the exchange failed")
    end

    def bearer(request)
      header = request.get_header("HTTP_AUTHORIZATION").to_s
      scheme, value = header.split(" ", 2)
      return value.to_s if scheme.to_s.casecmp("Bearer").zero?

      ""
    end

    def refusal(status, code, message)
      [status, { "content-type" => "application/json" },
        [JSON.generate(error: { code: code, message: message })]]
    end

    def not_found
      [404, { "content-type" => "application/json" },
        [JSON.generate(error: { code: "not_found", message: "no such route" })]]
    end

    def log(status:, box_id:, note:)
      # The box's id is not a secret — the operator is enrolling this box.
      # What is refused is a line naming the capability or the credential: a
      # log line is the one place a secret is copied, and the copy outlives
      # the credential.
      @logger.puts(JSON.generate(
        event: "registry.credential_exchange",
        status: status,
        box_id: box_id.to_s,
        note: note
      ))
    end
  end
end
