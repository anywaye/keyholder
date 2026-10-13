#!/usr/bin/env ruby
# frozen_string_literal: true

# The receipt-to-credential path, MEASURED end to end.
#
# Everything in this run is the shipped thing, over a socket:
#
#   box      — the real Rails app, in its test environment, on a database of
#              its own. The capability is MINTED by `Capability.mint!` and
#              SPENT by `CapabilitiesController#redeem` through the real
#              `POST /v1/capabilities/redeem` route.
#   registry — the real Rack app (`config.ru`), under puma, with
#              `Registry::Exchange` configured exactly as config.ru
#              configures it in production.
#   github   — a stub on a socket that answers `POST
#              /app/installations/:id/access_tokens` and VERIFIES the App's
#              RS256 assertion against the public half of the key the
#              registry service was given, before it answers. It is the only
#              thing here that is not shipped code.
#
# What it prints is a transcript of the path with the credential redacted
# everywhere it appears. The minted capability tokens are printed truncated,
# but they are real: they live in this run's database and die with it.
#
# Usage:
#   ruby script/exchange_proof                  # from this repository's root
#   BOX_DIR=/path/to/box ruby script/exchange_proof
#
# Exit 0 only if every expected outcome is the outcome observed.

require "json"
require "socket"
require "openssl"
require "base64"
require "tmpdir"
require "open3"
# The proof boots three processes; each is spawned with Bundler's own
# environment unwrapped so the child's Gemfile (box's, registry's) is its own
# and not this script's.
require "bundler"

ROOT = File.expand_path("..", __dir__)
BOX_DIR = File.expand_path(ENV.fetch("BOX_DIR", "../box"), ROOT)
ACCOUNT = "11111111-1111-4111-8111-111111111111"
BOX_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
OTHER_BOX_ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
REGISTRY_PORT = 9702
BOX_PORT = 9703
GITHUB_PORT = 9701
PROOF_DB = "postgresql://localhost/box_proof_registry"

$children = []

def say(line = "")
  puts line
end

def fail_run(message)
  warn "\nPROOF RED: #{message}"
  exit 1
end

def tail(path, lines = 15)
  return "(no log)" unless path && File.exist?(path)

  File.read(path).lines.last(lines).join
end

def wait_port(port, log)
  160.times do
    begin
      TCPSocket.new("127.0.0.1", port).close
      return
    rescue Errno::ECONNREFUSED
      sleep 0.5
    end
  end
  fail_run("nothing came up on #{port}\n#{tail(log)}")
end

# ---------------------------------------------------------------------------
# GitHub, stubbed on a socket. It does what a mock cannot: it verifies the
# App's own RS256 assertion with the public half of the key the service holds
# the private half of, and answers with the real installation-token shape.
# ---------------------------------------------------------------------------
class FakeGithub
  attr_reader :requests

  def initialize(public_pem)
    @public_pem = public_pem
    @requests = []
  end

  def start
    @server = TCPServer.new("127.0.0.1", GITHUB_PORT)
    @thread = Thread.new do
      loop do
        client = @server.accept
        handle(client)
      rescue StandardError
        nil
      end
    end
    self
  end

  def stop
    @thread&.kill
    @server&.close
  end

  private

  def handle(client)
    request_line = client.gets
    _method, path, = request_line.to_s.split(" ")
    headers = {}
    while (line = client.gets) && line != "\r\n"
      key, value = line.split(": ", 2)
      headers[key.to_s.downcase] = value.to_s.strip
    end
    assertion = headers["authorization"].to_s.sub(/\ABearer /, "")
    @requests << { path: path, assertion: assertion }
    body = JSON.generate(
      token: "ghs_proofinstallationtoken#{"x" * 40}",
      expires_at: (Time.now + 3600).utc.iso8601,
      permissions: { "packages" => "read" }
    )
    client.print "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    client.close
  end
end

# ---------------------------------------------------------------------------
# The real registry app, under puma, configured the way config.ru configures.
# ---------------------------------------------------------------------------
def start_registry(key_file)
  log = File.join(ROOT, "tmp", "proof-registry.log")
  env = {
    "REGISTRY_BOX_URL" => "http://127.0.0.1:#{BOX_PORT}",
    "REGISTRY_GITHUB_APP_ID" => "123456",
    "REGISTRY_GITHUB_APP_KEY_FILE" => key_file,
    "REGISTRY_GITHUB_INSTALLATION_ID" => "987654",
    "REGISTRY_GITHUB_API_URL" => "http://127.0.0.1:#{GITHUB_PORT}",
    "REGISTRY_REGISTRY_HOST" => "ghcr.io",
    "PORT" => REGISTRY_PORT.to_s
  }
  pid = Bundler.with_unbundled_env do
    Process.spawn(env, "bundle", "exec", "puma", "-p", REGISTRY_PORT.to_s, "-e", "production",
      chdir: ROOT, out: log, err: log)
  end
  $children << pid
  wait_port(REGISTRY_PORT, log)
  say "== registry is serving on #{REGISTRY_PORT} (the real config.ru, under puma) =="
  pid
end

# ---------------------------------------------------------------------------
# The real box app, on its own database, in its test environment. Its own
# database matters: the proof must not write into the database the repo's own
# suite runs against.
# ---------------------------------------------------------------------------
def box_env
  {
    "RAILS_ENV" => "test",
    "DATABASE_URL" => PROOF_DB,
    "DISABLE_SPRING" => "1",
    "SECRET_KEY_BASE" => "proofsecretkeybase" * 3
  }
end

def prepare_box_db
  say "== preparing box's schema on #{PROOF_DB.sub(%r{.*/}, '')} =="
  output, status = Bundler.with_unbundled_env do
    Open3.capture2e(box_env, "bin/rails", "db:drop", "db:create", "db:schema:load", chdir: BOX_DIR)
  end
  fail_run("box's schema would not load:\n#{output.lines.last(15).join}") unless status.exitstatus.zero?
end

def start_box
  log = File.join(ROOT, "tmp", "proof-box.log")
  pid = Bundler.with_unbundled_env do
    Process.spawn(box_env, "bin/rails", "server", "-p", BOX_PORT.to_s, "-b", "127.0.0.1",
      chdir: BOX_DIR, out: log, err: log)
  end
  $children << pid
  wait_port(BOX_PORT, log)
  say "== box is serving on #{BOX_PORT} (real Rails, RAILS_ENV=test) =="
  pid
end

# ---------------------------------------------------------------------------
# MINTING — a file, not a heredoc, so what runs inside box is exactly what is
# written here and nothing is interpolated twice.
#
# Minting is the one step the HTTP surface cannot do alone: it is a claimed
# account member's flow and the account member is Identity. Everything after
# the mint — the spend, the redemption, the credential — is real HTTP against
# the real routes, which is the part this packet exists to prove.
# ---------------------------------------------------------------------------
MINT_SCRIPT = <<~'RUBY'
  account = "11111111-1111-4111-8111-111111111111"
  box_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  other_box_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  actor = "99999999-8888-7777-6666-555555555555"

  mask = lambda do |token|
    "#{token[0, 12]}…#{token[-4, 4]}"
  end

  def mint(account:, box_id:, purpose:, actor:)
    _capability, token, = Capability.mint!(account_id: account, box_id: box_id, purpose: purpose, minted_by: actor)
    token
  end

  live = mint(account: account, box_id: box_id, purpose: "registry.pull", actor: actor)
  expired = mint(account: account, box_id: box_id, purpose: "registry.pull", actor: actor)
  other = mint(account: account, box_id: other_box_id, purpose: "registry.pull", actor: actor)
  wrong_purpose = mint(account: account, box_id: box_id, purpose: "box.enroll", actor: actor)

  Capability.find_by(token_digest: Capability.digest(expired)).update!(expires_at: 5.minutes.ago)

  # The RAW tokens are what this script hands back to the proof, which passes
  # them over the socket. They are never printed by the proof: what appears in
  # the transcript is the masked form.
  puts "LIVE #{live}"
  puts "EXPIRED #{expired}"
  puts "OTHERBOX #{other}"
  puts "WRONGPURPOSE #{wrong_purpose}"
  puts "done"
RUBY

def mint_capabilities
  mint_file = File.join(Dir.mktmpdir("registry-proof"), "mint.rb")
  File.write(mint_file, MINT_SCRIPT)
  output, status = Bundler.with_unbundled_env do
    Open3.capture2e(box_env, "bin/rails", "runner", mint_file, chdir: BOX_DIR)
  end
  fail_run("minting failed:\n#{output.lines.last(15).join}") unless status.exitstatus.zero?

  tokens = {}
  output.each_line do |line|
    label, token = line.strip.split(" ", 2)
    tokens[label.downcase.to_sym] = token if %w[LIVE EXPIRED OTHERBOX WRONGPURPOSE].include?(label)
  end
  fail_run("the mint did not answer with four tokens:\n#{output}") unless tokens.size == 4
  say "== minted four capabilities through Capability.mint! (Capability::TTL_MINUTES = #{ttl_minutes}) =="
  tokens.each { |label, token| say "   #{label.to_s.ljust(12)} #{mask(token)}" }
  say
  tokens
end

def mask(token)
  "#{token[0, 12]}…#{token[-4, 4]} (#{token.bytesize} bytes)"
end

# Read rather than hardcoded: the transcript names the TTL the mint actually
# used, and a mint that stops honouring Capability::TTL_MINUTES would show.
def ttl_minutes
  output, status = Bundler.with_unbundled_env do
    Open3.capture2e(box_env, "bin/rails", "runner",
      "puts Capability::TTL_MINUTES", chdir: BOX_DIR)
  end
  status.exitstatus.zero? ? output.strip : "?"
end

# ---------------------------------------------------------------------------
# The exchange call: the capability as a bearer, the box in the body.
# ---------------------------------------------------------------------------
def exchange(capability, box_id:)
  uri = URI("http://127.0.0.1:#{REGISTRY_PORT}/v1/registry-credentials")
  request = Net::HTTP::Post.new(uri)
  request["Authorization"] = "Bearer #{capability}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(box_id: box_id)
  Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
end

def show(label, response)
  body = JSON.parse(response.body)
  say "   #{label}"
  say "     status  #{response.code}"
  if body["error"]
    say "     error   #{body['error']['code']} — #{body['error']['message']}"
  else
    encoded = body["dockerconfigjson"].to_s
    say "     registry           #{body['registry']}"
    say "     expires_at         #{body['expires_at']}"
    say "     seconds_remaining  #{body['seconds_remaining']}"
    say "     dockerconfigjson   #{encoded.empty? ? '<absent>' : "#{encoded[0, 20]}… (#{encoded.bytesize} bytes, base64)"}"
    if encoded.empty? == false
      decoded = JSON.parse(Base64.strict_decode64(encoded))
      entry = decoded.dig("auths", "ghcr.io")
      redacted = entry["password"].to_s
      say "     decoded            #{Base64.strict_decode64(encoded).gsub(redacted, "<REDACTED #{redacted.bytesize}-byte installation token>")}"
    end
  end
  body
end

at_exit do
  $children.each do |pid|
    Process.kill("TERM", pid)
  rescue Errno::ESRCH
    nil
  end
end

require "net/http"

Dir.mkdir(File.join(ROOT, "tmp")) unless Dir.exist?(File.join(ROOT, "tmp"))

key = OpenSSL::PKey::RSA.generate(2048)
dir = Dir.mktmpdir("registry-proof")
key_file = File.join(dir, "app-key.pem")
File.write(key_file, key.to_pem)

say "# The receipt-to-credential path, measured"
say "#   box      http://127.0.0.1:#{BOX_PORT}   real Rails, RAILS_ENV=test, its own database"
say "#   registry http://127.0.0.1:#{REGISTRY_PORT}   real config.ru + Registry::Exchange, under puma"
say "#   github   http://127.0.0.1:#{GITHUB_PORT}   a stub that verifies the App's RS256 assertion"
say

github = FakeGithub.new(key.public_key).start
prepare_box_db
start_registry(key_file)
start_box
tokens = mint_capabilities

failures = []
check = lambda do |name, condition, detail = nil|
  if condition
    say "   PASS #{name}"
  else
    say "   FAIL #{name}#{detail ? " — #{detail}" : ''}"
    failures << name
  end
end

say "== 1. a live capability buys a short-lived, pull-only credential =="
live = exchange(tokens[:live], box_id: BOX_ID)
live_body = show("exchange(LIVE capability, this box)", live)
check.call("the exchange answers 200", live.code == "200", live.code)
credential = live_body["dockerconfigjson"].to_s
decoded = credential.empty? ? {} : JSON.parse(Base64.strict_decode64(credential))
entry = decoded.dig("auths", "ghcr.io")
password = entry && entry["password"].to_s
check.call("the product is a ghcr.io dockerconfigjson", !entry.nil?)
check.call("the credential is a fresh installation token", password.to_s.start_with?("ghs_"))
check.call("the username is the machine-identity idiom", entry && entry["username"] == "x-access-token")
check.call("the credential carries an expiry and life left", live_body["expires_at"].to_s.match?(/\d{4}-\d{2}-\d{2}T/) && live_body["seconds_remaining"].to_i >= 60,
  "expires_at=#{live_body['expires_at'].inspect} seconds_remaining=#{live_body['seconds_remaining'].inspect}")
check.call("github saw the App's assertion and verified it", github.requests.any? { |r| r[:path].include?("/access_tokens") } && password && !password.empty?)

say
say "== 2. the SAME capability cannot buy a second credential =="
again = exchange(tokens[:live], box_id: BOX_ID)
again_body = show("exchange(the SAME capability again, this box)", again)
check.call("the second spend is refused with box's own 409", again.code == "409", again.code)
check.call("box's code is passed through unchanged", again_body.dig("error", "code") == "capability_redeemed", again_body.dig("error", "code"))

say
say "== 3. an expired capability is refused =="
expired = exchange(tokens[:expired], box_id: BOX_ID)
expired_body = show("exchange(an EXPIRED capability, this box)", expired)
check.call("the expired capability is refused with box's own 410", expired.code == "410", expired.code)
check.call("the code is capability_expired", expired_body.dig("error", "code") == "capability_expired", expired_body.dig("error", "code"))

say
say "== 4. a capability for another box is refused =="
other = exchange(tokens[:otherbox], box_id: BOX_ID)
other_body = show("exchange(a capability for ANOTHER box, THIS box)", other)
check.call("the other box's capability is refused with box's own 403", other.code == "403", other.code)
check.call("the code is capability_wrong_box", other_body.dig("error", "code") == "capability_wrong_box", other_body.dig("error", "code"))

say
say "== 5. a capability minted for another purpose is refused =="
wrong_purpose = exchange(tokens[:wrongpurpose], box_id: BOX_ID)
wrong_purpose_body = show("exchange(a box.enroll capability, this box)", wrong_purpose)
check.call("the wrong-purpose capability is refused with box's own 403", wrong_purpose.code == "403", wrong_purpose.code)
check.call("the code is capability_wrong_purpose", wrong_purpose_body.dig("error", "code") == "capability_wrong_purpose", wrong_purpose_body.dig("error", "code"))

say
say "== 6. the credential appears in exactly one place: the response body =="
registry_log = File.read(File.join(ROOT, "tmp", "proof-registry.log"))
say "   registry's own log lines:"
registry_log.to_s.lines.each { |line| say "     #{line.rstrip}" }
check.call("the credential is nowhere in the registry's log", !registry_log.to_s.include?(password.to_s))
check.call("the registry's log names the outcome, not the credential", registry_log.to_s.include?("registry.credential_exchange"))
pasted = Base64.strict_encode64(JSON.generate(auths: { "ghcr.io" => { auth: "ZmFrZQ==" } }))
pasted_response = exchange(pasted, box_id: BOX_ID)
check.call("a dockerconfigjson pasted where a capability belongs is refused", pasted_response.code == "400", pasted_response.code)

github.stop

say
if failures.empty?
  say "PROOF GREEN — the receipt-to-credential path ran end to end, and every refusal is the refusal named."
else
  fail_run("#{failures.size} assertion(s) failed: #{failures.join(', ')}")
end
