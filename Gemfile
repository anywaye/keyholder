# frozen_string_literal: true

source "https://rubygems.org"

# The exchange is one HTTP request in and one HTTP request out. There is no
# database (the capability is box's row, not ours), no ActiveRecord and no
# Rails — the standard runtime library plus four gems is the whole runtime.
#
# The fleet's dependency rule (2026-10-13): a good existing library is the
# DEFAULT; writing our own is the exception whose reason is written at the
# code site. Every line below is that rule applied.

# The GitHub App JWT (RS256). THE library for this; hand-rolling an RS256
# JWT over OpenSSL would be thirty lines of security-critical base64url and
# padding, for no gain.
gem "jwt", "~> 3.3"

# Rack 3, the HTTP surface. `rackup` and `puma` are the server half.
gem "rack", "~> 3.1"
gem "rackup", "~> 2.2"
gem "puma", "~> 6.6"

# The installation-token request itself goes over net/http from the standard
# library. See lib/registry/authority.rb for why a GitHub API client (octokit)
# is NOT used: the reason is written at the code site, as the rule requires.

group :test do
  gem "minitest", "~> 5.25"
  # Drives the Rack app in-process, the way the fleet's request specs drive
  # Rails integration tests.
  gem "rack-test", "~> 2.2"
  gem "rake", "~> 13.4"
end
