# Devise configuration (task 3.1).
#
# Only :omniauthable and :timeoutable are used (see the User model). There is
# no password, remember-me, mailer or registration setting here on purpose.

# This file sorts before entra_auth.rb, so load the library itself
# (idempotent) before referencing EntraAuth::Config / EntraAuth::Strategy.
require "entra_auth"

Devise.setup do |config|
  require "devise/orm/active_record"

  config.parent_controller = "ApplicationController"

  # The users table has a display-only email column and no
  # database_authenticatable, so authentication keys are never normalized.
  config.case_insensitive_keys = []
  config.strip_whitespace_keys = []

  # Idle timeout (timeoutable). Read at boot; an invalid or unset setting
  # yields the default, so boot never fails here.
  config.timeout_in = EntraAuth::Config.idle_timeout

  # Sign-out resets the sessions of every scope.
  config.sign_out_all_scopes = true
  config.sign_out_via = :delete

  # Turbo-friendly responses.
  config.navigational_formats = [ "*/*", :html, :turbo_stream ]
  config.responder.error_status = :unprocessable_entity
  config.responder.redirect_status = :see_other

  # Entra ID (single tenant) provider. Environment-dependent options are
  # resolved per request through OmniAuth's :setup hook, so boot (development,
  # test, asset precompile) never requires ENTRA_* settings. When a value is
  # missing it stays nil and the strategy fails through fail! (the login
  # screen checks EntraAuth::Config.valid? first).
  entra_setup = lambda do |env|
    options = env["omniauth.strategy"]&.options
    next unless options

    options.issuer = EntraAuth::Config.issuer
    options.client_options.identifier = EntraAuth::Config.client_id
    options.client_options.secret = EntraAuth::Config.client_secret
    options.client_options.redirect_uri = EntraAuth::Config.redirect_uri
  end

  config.omniauth :openid_connect, strategy_class: EntraAuth::Strategy, setup: entra_setup
end
