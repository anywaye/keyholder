# frozen_string_literal: true

require "cgi"
require "openssl"
require "base64"
require "json"
require "time"

module Registry
  # A short-lived, pull-only dockerconfigjson — the exchange's product.
  #
  # ## The scope is carried, not asserted
  #
  # `#pull_only?` is not a check this class performs on itself; it reads the
  # permissions GitHub granted the installation token and answers whether
  # every one of them is read-level. The registry service refuses to return a
  # credential that is not pull-only, so the question "is this pull-only" has
  # an actual answer at runtime rather than a hopeful comment.
  #
  # ## The credential is never written down
  #
  # Nothing in this class writes to a log, a file, or stdout. `#redacted` is
  # the only representation suitable for a report or a log line: it keeps the
  # shape and replaces the secret. `#inspect` is overridden for the same
  # reason (see test/exchange_test.rb for the assertion that a value dropped
  # into an exception, a log line and an interpolated string stays redacted).
  class Minted
    # Username paired with the installation token. GitHub accepts any
    # username with a valid installation access token; `x-access-token` is the
    # Kubernetes-and-Docker idiom for a machine credential whose identity lives
    # in the token. The app's own bot name would work equally well.
    USERNAME = "x-access-token"

    def initialize(token:, expires_at:, permissions:, registry: nil)
      @token = token.to_s
      @expires_at = expires_at
      @permissions = permissions || {}
      @registry = (registry || "ghcr.io").to_s
      raise ArgumentError, "a minted credential must carry a token" if @token.strip.empty?
      raise ArgumentError, "a minted credential must carry an expiry" if @expires_at.nil?
    end

    attr_reader :token, :expires_at, :permissions

    def registry
      @registry
    end

    # Expiry in seconds from now, floored at zero. A credential GitHub says
    # has already expired is a credential with zero life left, and the
    # exchange refuses to return one (see Exchange).
    def seconds_remaining(now: Time.now)
      [(expires_at - now).to_i, 0].max
    end

    def expired?(now: Time.now)
      expires_at <= now
    end

    # True when every permission GitHub granted is read-level. `read` is
    # pull. `write`, `maintain` and `admin` are not. An empty permission set
    # answers TRUE — an installation token with no permissions cannot pull
    # either, and `Exchange` refuses an unusable credential separately; the
    # risk this guards against is a credentialed push, which is what a
    # pull-only posture exists to prevent.
    def pull_only?
      return false if @permissions.nil? || @permissions.empty?

      @permissions.values.all? { |value| value.to_s == "read" }
    end

    def usable?(now: Time.now)
      !expired?(now: now) && !token.strip.empty? && seconds_remaining(now: now) > 0
    end

    # The dockerconfigjson exactly as Kubernetes expects to find it, already
    # base64-encoded — `kubectl create secret docker-registry ... --from-file`
    # takes the encoded form. Returning it encoded spares the caller a second
    # place to get base64 wrong, and it is the only string in this service
    # that contains the credential.
    def dockerconfigjson
      {
        "auths" => {
          registry => {
            "username" => USERNAME,
            "password" => token,
            "email" => ""
          }
        }
      }.to_json
    end

    # The base64 dockerconfigjson, the form that goes into a Secret.
    def encoded_dockerconfigjson
      Base64.strict_encode64(dockerconfigjson)
    end

    # A representation that is safe in a log line, a report or an exception
    # message: the shape is preserved so a reader can confirm what was minted,
    # and the secret is gone.
    def redacted
      "Minted(registry=#{registry}, expires_at=#{expires_at.utc.iso8601}, " \
        "seconds_remaining=#{seconds_remaining}, pull_only=#{pull_only?}, " \
        "permissions=#{@permissions.keys.sort.join(',') || 'none'})"
    end

    # The Secret's `.dockerconfigjson` value is the whole credential, so the
    # class renders as its redacted form anywhere it is interpolated. A
    # stack trace that prints the token is the leak this prevents.
    def inspect
      redacted
    end

    def to_s
      redacted
    end
  end
end
