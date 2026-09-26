require "omniauth_openid_connect"

module EntraAuth
  # Entra ID (single tenant) OpenID Connect strategy. Registered under the
  # gem's name (`openid_connect`). Only the fixed options live here; the caller
  # passes issuer and client_options (identifier, secret, redirect_uri).
  # state / nonce stay enabled (gem defaults).
  #
  # NOTE: only the gem superclass may be referenced at class-body level
  # (lib/entra_auth/*.rb are required in sorted order).
  class Strategy < OmniAuth::Strategies::OpenIDConnect
    option :discovery, true
    option :response_type, :code
    option :pkce, true
    option :scope, %i[openid profile email]
    # rack-oauth2 sends client_id / client_secret in the token request body for
    # any value other than :basic and the JWT/mTLS variants.
    option :client_auth_method, :post

    private

    # The stock gem merges the userinfo (Microsoft Graph) response into the ID
    # token claims and fails sign-in when Graph is unreachable. Sign-in must
    # rely on the verified ID token claims only, so build the user info from
    # them. Depends on the gem's private #access_token / #decode_id_token
    # (omniauth_openid_connect is pinned to ~> 0.8.0; guarded by strategy_test).
    def user_info
      return @user_info if @user_info

      @user_info = ::OpenIDConnect::ResponseObject::UserInfo.new(
        decode_id_token(access_token.id_token).raw_attributes
      )
    end
  end
end
