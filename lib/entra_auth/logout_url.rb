require "uri"

module EntraAuth
  # Builds the Entra ID RP-Initiated Logout URL. Deterministic from Config:
  # no HTTP request and no discovery.
  #
  # Only post_logout_redirect_uri and (when present) logout_hint are sent.
  # id_token_hint, client_id and secrets are never included. Without a hint
  # Entra ID shows its account picker (degraded but valid).
  #
  # build returns nil when Config cannot supply the tenant or the
  # post-logout URI; it never raises for missing configuration. The caller
  # (SessionsController) then falls back to a local page: app-side sign-out
  # never depends on Entra ID.
  #
  # Load order: other EntraAuth constants are referenced only inside methods.
  class LogoutUrl
    ENDPOINT = "https://login.microsoftonline.com/%<tenant>s/oauth2/v2.0/logout".freeze

    class << self
      def build(logout_hint: nil)
        tenant = EntraAuth::Config.tenant_id
        redirect = EntraAuth::Config.post_logout_redirect_uri
        return nil unless tenant && redirect && EntraAuth::Config::GUID_PATTERN.match?(tenant)

        params = [ [ "post_logout_redirect_uri", redirect ] ]
        hint = logout_hint.to_s.strip
        params << [ "logout_hint", logout_hint.to_s ] unless hint.empty?

        "#{format(ENDPOINT, tenant: tenant)}?#{URI.encode_www_form(params)}"
      end
    end
  end
end
