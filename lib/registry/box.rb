# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Registry
  # Box's redeem door, as this service calls it.
  #
  # ## Why the capability is spent HERE and not by the caller
  #
  # The installer used to redeem at box and then have nowhere to go with the
  # receipt. The exchange now spends the capability itself, through this
  # client, exactly once: box's `Capability.redeem!` enforces the single-use
  # claim atomically (`UPDATE ... WHERE redeemed_at IS NULL`), the purpose
  # binding and the box binding server-side, so the registry service never
  # has to trust the caller to have checked. That is the whole point of
  # option (b): box stays the one door that spends capabilities, and the
  # registry service is the one process that holds registry material. Neither
  # holds the other's secret.
  #
  # ## A refusal is a refusal
  #
  # Every box refusal (4xx) becomes a `Box::Refusal` carrying box's own status
  # and error code. The exchange maps it out unchanged, so the operator hears
  # "this capability is expired" from the same vocabulary the installer
  # already speaks, rather than a registry-shaped guess about why.
  class Box
    class Error < StandardError; end
    class Refusal < Error
      attr_reader :status, :code

      def initialize(status:, code:, message:)
        @status = status
        @code = code
        super(message)
      end
    end
    class Unreachable < Error; end

    def initialize(url:, token:, opener: nil, timeout: 10)
      @url = url.to_s.chomp("/")
      @token = token.to_s
      raise ArgumentError, "box url is required" if @url.empty?
      raise ArgumentError, "the capability is required" if @token.empty?

      @opener = opener
      @timeout = timeout
    end

    attr_reader :url, :token, :opener

    # Spend the capability for a registry.pull on this box. Returns box's
    # receipt hash (its `capability` object). Raises Box::Refusal.
    def redeem(box_id:)
      response = request(
        Net::HTTP::Post,
        "#{@url}/v1/capabilities/redeem",
        body: JSON.generate(
          token: @token,
          purpose: "registry.pull",
          box_id: box_id
        )
      )
      capability = response["capability"]
      raise Refusal.new(status: 502, code: "bad_upstream",
        message: "box's receipt carries no capability") if capability.nil?

      capability
    end

    private

    def request(klass, url, body: nil)
      uri = URI.parse(url)
      request = klass.new(uri)
      request["Content-Type"] = "application/json"
      # The capability travels as a bearer, the same way the installer used to
      # present it — and the same reason box's redeem route prefers the
      # header: a token in a path lands in access logs.
      request["Authorization"] = "Bearer #{@token}"
      request.body = body if body
      response = (opener || Net::HTTP).new(uri.host, uri.port).tap { |http|
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @timeout
        http.read_timeout = @timeout
      }.start { |http| http.request(request) }

      case response
      when Net::HTTPSuccess
        JSON.parse(response.body)
      when Net::HTTPClientError, Net::HTTPServerError
        parsed = begin
          JSON.parse(response.body)
        rescue JSON::ParserError
          {}
        end
        code = parsed.dig("error", "code") || "box_refused"
        message = parsed.dig("error", "message") || "box refused the capability (#{response.code})"
        raise Refusal.new(status: response.code.to_i, code: code, message: message)
      else
        raise Unreachable, "box answered #{response.code}"
      end
    rescue JSON::ParserError => e
      raise Unreachable, "box's response is not JSON: #{e.message}"
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError, Net::OpenTimeout,
           Net::ReadTimeout => e
      raise Unreachable, "box is not reachable: #{e.class}"
    end
  end
end
