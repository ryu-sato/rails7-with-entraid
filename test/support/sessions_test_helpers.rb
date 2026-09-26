# Shared helpers for the SessionsController tests (task 4.1).
module SessionsTestHelpers
  ENTRA_ENV_NAMES = %w[
    ENTRA_TENANT_ID ENTRA_CLIENT_ID ENTRA_CLIENT_SECRET ENTRA_APP_BASE_URL
    ENTRA_SESSION_IDLE_MINUTES ENTRA_SESSION_ABSOLUTE_HOURS
  ].freeze

  # Runs the block with the given ENTRA_* env overrides (nil unsets a key),
  # and no credentials.entra_id; restores ENV afterwards.
  def with_entra_env(overrides = {})
    saved = ENTRA_ENV_NAMES.to_h { |name| [ name, ENV[name] ] }
    overrides.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    Rails.application.credentials.stub(:entra_id, nil) { yield }
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  # Signs a user in for the NEXT request (Devise sign_in helper) and, when a
  # hint is given, plants logout_hint in the Warden session during that same
  # request (Warden.on_next_request callbacks run in registration order).
  def sign_in_with_hint(user, hint = nil)
    sign_in user
    return unless hint

    Warden.on_next_request { |proxy| proxy.session(:user)["logout_hint"] = hint }
  end

  # Runs the block with request forgery protection enabled; restores after.
  def with_forgery_protection
    saved = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = saved
  end

  def form_token(html)
    Nokogiri::HTML(html).at_css("form input[name=authenticity_token]")&.[]("value")
  end

  def meta_token(html)
    Nokogiri::HTML(html).at_css("meta[name=csrf-token]")&.[]("content")
  end

  def capture_rails_log
    io = StringIO.new
    Rails.stub(:logger, ActiveSupport::Logger.new(io)) { yield }
    io.string
  end
end
