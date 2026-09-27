# Login page, sign-out and the post-sign-out page. Devise has no sessions
# routes for an omniauthable-only model, so these are our own routes.
class SessionsController < ApplicationController
  # raise: false: the default authenticate_user! is added to
  # ApplicationController later; these entry points must stay public.
  skip_before_action :authenticate_user!, only: %i[new signed_out destroy], raise: false

  def new
    unless EntraAuth::Config.valid?
      # Item names only, never values.
      Rails.logger.warn("Entra ID configuration is invalid: #{EntraAuth::Config.problems.join(', ')}")
      render :unavailable, status: :service_unavailable
      return
    end

    redirect_to after_sign_in_path_for(current_user) if user_signed_in?
  end

  def destroy
    logout_hint = warden.session(:user)["logout_hint"] if warden.authenticated?(:user)

    # Invalidate every earlier session cookie of this user (server side) while
    # still authenticated. Fail-safe: the app sign-out below always runs, even
    # if the rotation fails (only the exception class is logged, never the
    # message). Not reachable for an already expired session (residual risk,
    # bounded by the idle/absolute timeouts).
    begin
      current_user.rotate_session_token! if warden.authenticated?(:user)
    rescue StandardError => e
      Rails.logger.error("Session token rotation failed: #{e.class}")
    ensure
      # End the app session first: it must not depend on Entra ID.
      sign_out
    end

    url = EntraAuth::LogoutUrl.build(logout_hint: logout_hint)
    if url
      # The only external redirect in the app: Entra ID's sign-out endpoint.
      redirect_to url, allow_other_host: true, status: :see_other
    else
      redirect_to signed_out_path, status: :see_other
    end
  end

  def signed_out; end
end
