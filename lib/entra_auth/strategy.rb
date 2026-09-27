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

    # Every failure ends in fail!(key, exception); nothing propagates. Only
    # StandardError is rescued (InvalidToken and JSON::JWT::Exception are
    # StandardError subclasses in the pinned gems), never Exception. Keys:
    #   :invalid_id_token  ID token validation / signature errors
    #   :discovery_failed  discovery or jwks fetch failed
    #   :timeout / :failed_to_connect  transport errors (gem key names)
    #   :callback_error    anything else
    # Keys the gem itself emits (:csrf_detected, IdP errors such as
    # :access_denied, token endpoint errors such as :invalid_grant) pass through.
    def request_phase
      return fail!(:invalid_configuration) if configuration_incomplete?

      super
    rescue StandardError => e
      fail!(failure_key_for(e), e)
    end

    def callback_phase
      return fail!(:invalid_configuration) if configuration_incomplete?

      super
    rescue StandardError => e
      # An error raised by the downstream app (call_app!) is not an
      # authentication failure; let it propagate untouched.
      raise if env["omniauth.error.app"]

      fail!(failure_key_for(e), e)
    end

    # Public in the gem (used while verifying the ID token): tag jwks fetch
    # failures so they map to :discovery_failed.
    def public_key
      super
    rescue StandardError
      @failure_key ||= :discovery_failed
      raise
    end

    # OmniAuth's own #fail! logs "<key>: <Class>, <exception.message>" through
    # OmniAuth.logger (STDOUT by default, separate from Rails.logger); the
    # message can carry IdP / HTTP body text (AADSTS...), claims or token
    # fragments. Same behavior as the gem (env keys, on_failure), but the log
    # line has the key and the exception CLASS only. The key can come from the
    # IdP's `error` parameter, so it is reduced to a safe token.
    def fail!(message_key, exception = nil)
      env["omniauth.error"] = exception
      env["omniauth.error.type"] = message_key.to_sym
      env["omniauth.error.strategy"] = self

      log_key = message_key.to_s.gsub(/[^\w.-]/, "_").first(64)
      log :error, "Authentication failure! #{log_key}: #{exception ? exception.class : 'none'}"

      OmniAuth.config.on_failure.call(env)
    end

    private

    # An incomplete configuration must fail before any external communication:
    # a blank issuer would otherwise send the gem into WebFinger discovery
    # against a bogus host. Only the options are inspected (set by the caller).
    def configuration_incomplete?
      client = options.client_options
      [ options.issuer, client&.identifier, client&.secret, client&.redirect_uri ].any? { |v| v.to_s.strip.empty? }
    end

    # The stock gem merges the userinfo (Microsoft Graph) response into the ID
    # token claims and fails sign-in when Graph is unreachable. Sign-in must
    # rely on the verified ID token claims only, so build the user info from
    # them. Depends on the gem's private #access_token / #decode_id_token
    # (omniauth_openid_connect is pinned to ~> 0.8.0; guarded by strategy_test).
    def user_info
      return @user_info if @user_info

      id_token = access_token.id_token
      raise ::OpenIDConnect::ResponseObject::IdToken::InvalidToken, "ID token missing from token response" if id_token.blank?

      @user_info = ::OpenIDConnect::ResponseObject::UserInfo.new(decode_id_token(id_token).raw_attributes)
    end

    def discover!
      super
    rescue StandardError
      @failure_key ||= :discovery_failed
      raise
    end

    def failure_key_for(error)
      case error
      when ::OpenIDConnect::ResponseObject::IdToken::InvalidToken, ::JSON::JWT::Exception then :invalid_id_token
      else
        @failure_key || transport_failure_key(error) || :callback_error
      end
    end

    # The HTTP layer is Faraday, which wraps Timeout::Error / SocketError, so
    # the gem's own :timeout / :failed_to_connect rescues rarely see them.
    # Keep the gem's key names for those cases.
    def transport_failure_key(error)
      case error
      when ::Faraday::TimeoutError, ::Timeout::Error then :timeout
      when ::Faraday::ConnectionFailed, ::SocketError then :failed_to_connect
      end
    end
  end
end
