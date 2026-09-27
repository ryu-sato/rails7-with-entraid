# Turns a refused permission check (CanCan::AccessDenied, raised by authorize!)
# into a uniform answer for the whole app.
#
# - Signed-in user: 403. HTML gets the permission-denied screen; any other
#   format gets a bare 403. Nothing about roles, rules or the exception is shown.
# - Signed-out user: not a permission problem. Hand over to authentication's
#   sign-in flow (authenticate_user!) instead of answering 403.
#
# authorize! must be called before the action performs any change: this handler
# only answers, it never undoes anything.
module AuthorizationHandling
  extend ActiveSupport::Concern

  included do
    rescue_from CanCan::AccessDenied, with: :render_forbidden
  end

  private

  def render_forbidden(_exception)
    return authenticate_user! unless user_signed_in?

    # Who and where only: never the roles or the exception message.
    Rails.logger.warn("[authorization] access denied user_id=#{current_user.id} " \
                      "action=#{controller_path}##{action_name}")

    respond_to do |format|
      format.html { render "errors/forbidden", status: :forbidden }
      format.any { head :forbidden }
    end
  end
end
