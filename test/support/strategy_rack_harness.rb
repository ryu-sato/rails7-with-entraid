require "rack/test"
require "base64"
require "digest"

# Shared Rack harness for EntraAuth::Strategy tests. Drives the strategy
# through a real Rack stack (session + strategy + terminal app) WITHOUT
# OmniAuth.config.test_mode, because test_mode bypasses the strategy's
# request/callback phases. discovery / jwks / token are WebMock stubs from
# OidcProviderStub; nothing talks to a real Entra ID.
module StrategyRackHarness
  extend ActiveSupport::Concern

  REDIRECT_URI = "http://www.example.com/auth/openid_connect/callback".freeze
  CLIENT_SECRET = OidcProviderStub::FAKE_CLIENT_SECRET

  # Sits between the session middleware and the strategy and records the
  # session as it is after each request (the strategy may redirect without
  # ever calling the terminal app).
  class SessionProbe
    def initialize(app, sink)
      @app = app
      @sink = sink
    end

    def call(env)
      @app.call(env)
    ensure
      @sink << env["rack.session"].to_h.dup
    end
  end

  included do
    include Rack::Test::Methods

    setup do
      install_oidc_provider_stub
      @auth_results = []
      @sessions = []
      @fail_keys = []
      @fail_errors = []
      @saved_validation_phase = OmniAuth.config.request_validation_phase
      # omniauth-rails_csrf_protection installs a validator that needs a Rails
      # authenticity token; this standalone Rack app has no Rails controller
      # to issue one, so the request-phase CSRF check is turned off here only
      # (restored in teardown). CSRF on the real route is covered by task 3.x.
      OmniAuth.config.request_validation_phase = ->(_env) { }
      @saved_test_mode = OmniAuth.config.test_mode
      @saved_on_failure = OmniAuth.config.on_failure
      # fail! hands over to on_failure; record the failure key (and the
      # exception object) instead of redirecting.
      fail_keys = @fail_keys
      fail_errors = @fail_errors
      OmniAuth.config.on_failure = lambda do |env|
        fail_keys << env["omniauth.error.type"]
        fail_errors << env["omniauth.error"]
        [ 500, { "content-type" => "text/plain" }, [ "failed" ] ]
      end
      OmniAuth.config.test_mode = false
    end

    teardown do
      OmniAuth.config.request_validation_phase = @saved_validation_phase
      OmniAuth.config.test_mode = @saved_test_mode
      OmniAuth.config.on_failure = @saved_on_failure
    end
  end

  def strategy_class = EntraAuth::Strategy

  def strategy_options(overrides = {})
    {
      # Devise (config/initializers/devise.rb) clears the global OmniAuth
      # path_prefix (it sets it per mapping); this standalone stack keeps
      # the default /auth prefix explicitly.
      path_prefix: "/auth",
      issuer: oidc_stub.issuer,
      client_options: {
        identifier: oidc_stub.client_id,
        secret: CLIENT_SECRET,
        redirect_uri: REDIRECT_URI
      }
    }.merge(overrides)
  end

  def build_app(klass, options)
    auth_results = @auth_results
    sessions = @sessions
    terminal = lambda do |env|
      auth_results << env["omniauth.auth"]
      [ 200, { "content-type" => "text/plain" }, [ "signed in" ] ]
    end
    Rack::Builder.new do
      use Rack::Session::Cookie, secret: SecureRandom.hex(64), same_site: :lax
      use SessionProbe, sessions
      use klass, options
      run terminal
    end.to_app
  end

  def app
    @app ||= build_app(strategy_class, strategy_options)
  end

  def authorize_params
    location = URI(last_response.headers["location"])
    [ location, Rack::Utils.parse_query(location.query) ]
  end

  def sign_in_with(**id_token_overrides)
    post "/auth/openid_connect"
    _location, params = authorize_params
    oidc_stub.token_response_id_token = oidc_stub.id_token(nonce: params["nonce"], **id_token_overrides)
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]
    params
  end
end
