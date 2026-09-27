module Users
  # Completes the OIDC sign-in (callback) and handles OmniAuth failures.
  class OmniauthCallbacksController < Devise::OmniauthCallbacksController
    # Reachable while signed out. raise: false: the default authenticate_user!
    # is added to ApplicationController later (devise_controller? also exempts).
    skip_before_action :authenticate_user!, raise: false

    # failure is only reached through OmniAuth's on_failure (it has no route). A
    # rejected authenticity token at the sign-in start (POST without a token)
    # also ends up here, so the token check must not run for it or that very
    # failure would surface as a 422 instead of returning to the login page.
    skip_forgery_protection only: :failure

    def openid_connect
      # Never read auth.credentials (access token / ID token): 2.6.
      identity = EntraAuth::VerifiedIdentity.from_auth_hash(
        request.env["omniauth.auth"], expected_tenant_id: EntraAuth::Config.tenant_id
      )
      user = User.from_identity(identity)
      decision = EntraAuth::SignInGate.evaluate(identity, user)

      if decision.accepted?
        complete_sign_in(user, identity)
      else
        Rails.logger.warn("[Users::OmniauthCallbacks] sign-in rejected reason=#{decision.reason}")
        reject_with(decision.message.presence || t_failure(:rejected))
      end
    rescue EntraAuth::VerifiedIdentity::Invalid => e
      Rails.logger.warn("[Users::OmniauthCallbacks] invalid identity reason=#{e.reason}")
      reject_with(t_failure(:failed))
    rescue StandardError => e
      # Class name only: messages may carry claims.
      Rails.logger.error("[Users::OmniauthCallbacks] sign-in error class=#{e.class.name}")
      reject_with(t_failure(:failed))
    end

    def failure
      key = request.env["omniauth.error.type"]
      error = request.env["omniauth.error"]
      # Key and exception class only: never the message, claims or tokens (4.3, 4.4).
      # The key can be the IdP's `error` parameter: reduce it to a safe token.
      log_key = key.to_s.gsub(/[^\w.-]/, "_").first(64)
      Rails.logger.warn("[Users::OmniauthCallbacks] failure key=#{log_key.presence || 'unknown'} " \
                        "error=#{error ? error.class.name : 'none'}")
      flash[:alert] = t_failure(key.to_s == "access_denied" ? :cancelled : :failed)
      redirect_to after_omniauth_failure_path_for(resource_name), status: :see_other
    end

    protected

    def after_omniauth_failure_path_for(_scope)
      new_user_session_path
    end

    private

    def complete_sign_in(user, identity)
      sign_in(:user, user, event: :authentication)
      hint = identity.login_hint
      warden.session(:user)["logout_hint"] = hint if hint.present?
      redirect_to after_sign_in_path_for(user), status: :see_other
    end

    def reject_with(message)
      flash[:alert] = message
      redirect_to new_user_session_path, status: :see_other
    end

    def t_failure(key)
      I18n.t("entra_authentication.failures.#{key}")
    end
  end
end
