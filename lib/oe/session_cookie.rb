# frozen_string_literal: true

module Oe
  # Options for Rack::Session::Cookie (#286).
  #
  # Production is served only over https (oe.witzman.de, HSTS), but behind
  # Apache and Traefik, which do not reliably pass X-Forwarded-Proto: https.
  # Rack then sees plain http and, for a `secure` cookie, silently writes NO
  # Set-Cookie (rack-session `security_matches?`) -- /login answers 200 and the
  # next request has no session. `assume_ssl` is rack-session's own switch for
  # exactly this case: write the Secure cookie although the request looks like
  # http. The browser still gets `Secure` and only ever talks https.
  #
  # Test/development run over plain http and use neither flag.
  module SessionCookie
    def self.options(production:)
      {
        key: "oe.session",
        same_site: :lax,
        httponly: true,
        secure: production,
        assume_ssl: production,
      }
    end
  end
end
