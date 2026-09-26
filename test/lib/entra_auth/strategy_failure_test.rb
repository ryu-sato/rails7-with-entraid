require "test_helper"

# Task 2.3: every failure of EntraAuth::Strategy ends in fail! (recorded here
# by the on_failure stub): no session is started (no omniauth.auth reaches the
# app), no exception propagates out of the Rack stack, and nothing sensitive
# (claims, tokens, exception messages) appears in the response.
class EntraAuthStrategyFailureTest < ActiveSupport::TestCase
  include StrategyRackHarness

  # A non-StandardError, non-listed Exception. Must never be swallowed.
  class FatalStub < Exception; end # rubocop:disable Lint/InheritException

  INVALID_TOKEN = ::OpenIDConnect::ResponseObject::IdToken::InvalidToken
  SENTINEL_EMAIL = "sentinel.user@example.com".freeze

  def other_tenant = "99999999-8888-7777-6666-555555555555"

  def json_headers = { "Content-Type" => "application/json" }

  # Runs the full round trip with the given claim overrides and asserts the
  # failure shape. Returns the recorded exception.
  def assert_sign_in_fails(key, error_class: nil, **overrides)
    sign_in_with(**overrides)
    assert_failed(key, error_class: error_class)
  end

  def assert_failed(key, error_class: nil)
    assert_empty @auth_results, "no auth result may reach the app on failure"
    assert_equal [ key ], @fail_keys
    error = @fail_errors.last
    assert_kind_of error_class, error if error_class
    assert_response_clean(error)
    error
  end

  # Neither claims, tokens, the client secret nor the exception message may
  # leak into what the browser receives.
  def assert_response_clean(error = nil)
    visible = [ last_response.body, last_response.headers.to_a.flatten.join(" ") ].join(" ")
    forbidden = [ SENTINEL_EMAIL, "test.user@example.com", "test-access-token", CLIENT_SECRET,
                  oidc_stub.token_response_id_token.to_s, "auth-code-1" ].reject(&:blank?)
    forbidden << error.message if error && error.message.present?
    forbidden.each { |secret| assert_not_includes visible, secret }
  end

  # ---- ID token validation (callback phase) -------------------------------

  test "issuer from another tenant is rejected as invalid_id_token" do
    assert_sign_in_fails :invalid_id_token, error_class: INVALID_TOKEN,
                         iss: "https://login.microsoftonline.com/#{other_tenant}/v2.0"
  end

  test "issuer of the wrong version (v1.0 sts) is rejected as invalid_id_token" do
    assert_sign_in_fails :invalid_id_token, error_class: INVALID_TOKEN,
                         iss: "https://sts.windows.net/#{oidc_stub.tenant_id}/"
  end

  test "audience mismatch is rejected as invalid_id_token" do
    assert_sign_in_fails :invalid_id_token, error_class: INVALID_TOKEN, aud: "someone-else"
  end

  test "expired ID token is rejected as invalid_id_token" do
    assert_sign_in_fails :invalid_id_token, error_class: INVALID_TOKEN, exp: Time.now.to_i - 3600
  end

  test "nonce mismatch is rejected as invalid_id_token" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    oidc_stub.token_response_id_token = oidc_stub.id_token(nonce: "not-the-nonce-we-sent")
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_failed :invalid_id_token, error_class: INVALID_TOKEN
  end

  test "missing nonce claim is rejected as invalid_id_token" do
    assert_sign_in_fails :invalid_id_token, error_class: INVALID_TOKEN, nonce: nil
  end

  test "ID token signed by another key is rejected as invalid_id_token (JSON::JWT::Exception family)" do
    other_key = OpenSSL::PKey::RSA.generate(2048)
    post "/auth/openid_connect"
    _location, params = authorize_params
    jwt = JSON::JWT.new(oidc_stub.default_claims.merge(nonce: params["nonce"]))
    jwt.kid = oidc_stub.kid
    oidc_stub.token_response_id_token = jwt.sign(other_key, :RS256).to_s
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_failed :invalid_id_token, error_class: JSON::JWT::Exception
  end

  test "unsecured (alg none) ID token is rejected" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    jwt = JSON::JWT.new(oidc_stub.default_claims.merge(nonce: params["nonce"]))
    jwt.kid = oidc_stub.kid
    oidc_stub.token_response_id_token = jwt.to_s # alg none
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_empty @auth_results
    assert_equal 1, @fail_keys.size
  end

  test "malformed id_token string is a failure, not an exception" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    oidc_stub.token_response_id_token = "not-a-jwt"
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_empty @auth_results
    assert_equal 1, @fail_keys.size
    assert_response_clean(@fail_errors.last)
  end

  test "token response without id_token fails closed as a failure with no propagation" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    oidc_stub.token_response_id_token = nil
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_failed :invalid_id_token
  end

  test "claims never appear in the response even when the token carries an email" do
    assert_sign_in_fails :invalid_id_token, error_class: INVALID_TOKEN, aud: "someone-else", email: SENTINEL_EMAIL
  end

  # ---- state (gem keys pass through) --------------------------------------

  test "state mismatch passes through as csrf_detected" do
    post "/auth/openid_connect"
    get "/auth/openid_connect/callback", code: "auth-code-1", state: "forged-state"

    assert_failed :csrf_detected
  end

  test "missing state passes through as csrf_detected" do
    post "/auth/openid_connect"
    get "/auth/openid_connect/callback", code: "auth-code-1"

    assert_failed :csrf_detected
  end

  test "callback without a prior request phase (no stored state) is csrf_detected" do
    get "/auth/openid_connect/callback", code: "auth-code-1", state: "anything"

    assert_failed :csrf_detected
  end

  # ---- discovery / jwks ---------------------------------------------------

  test "discovery HTTP 500 in the request phase becomes discovery_failed" do
    WebMock.stub_request(:get, oidc_stub.discovery_url).to_return(status: 500, body: "boom-internal-detail")
    post "/auth/openid_connect"

    assert_failed :discovery_failed
    assert_not last_response.redirect?
  end

  test "discovery timeout in the request phase becomes discovery_failed" do
    WebMock.stub_request(:get, oidc_stub.discovery_url).to_timeout
    post "/auth/openid_connect"

    assert_failed :discovery_failed
    assert_not last_response.redirect?
  end

  test "discovery connection failure in the request phase becomes discovery_failed" do
    WebMock.stub_request(:get, oidc_stub.discovery_url).to_raise(SocketError)
    post "/auth/openid_connect"

    assert_failed :discovery_failed
  end

  test "discovery HTTP 500 in the callback phase becomes discovery_failed" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    oidc_stub.token_response_id_token = oidc_stub.id_token(nonce: params["nonce"])
    WebMock.stub_request(:get, oidc_stub.discovery_url).to_return(status: 500, body: "boom-internal-detail")
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_failed :discovery_failed
  end

  test "discovery timeout in the callback phase becomes discovery_failed" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    WebMock.stub_request(:get, oidc_stub.discovery_url).to_timeout
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_failed :discovery_failed
  end

  test "discovery document that is not JSON becomes discovery_failed" do
    WebMock.stub_request(:get, oidc_stub.discovery_url).to_return(status: 200, body: "<html>captive portal</html>")
    post "/auth/openid_connect"

    assert_failed :discovery_failed
  end

  test "jwks fetch HTTP 500 becomes discovery_failed" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    oidc_stub.token_response_id_token = oidc_stub.id_token(nonce: params["nonce"])
    WebMock.stub_request(:get, oidc_stub.jwks_uri).to_return(status: 500, body: "boom-internal-detail")
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_failed :discovery_failed
  end

  test "jwks fetch timeout becomes discovery_failed" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    oidc_stub.token_response_id_token = oidc_stub.id_token(nonce: params["nonce"])
    WebMock.stub_request(:get, oidc_stub.jwks_uri).to_timeout
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_failed :discovery_failed
  end

  test "jwks response that is not JSON becomes discovery_failed" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    oidc_stub.token_response_id_token = oidc_stub.id_token(nonce: params["nonce"])
    WebMock.stub_request(:get, oidc_stub.jwks_uri).to_return(status: 200, body: "<html>captive portal</html>")
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_failed :discovery_failed
  end

  # ---- token endpoint -----------------------------------------------------

  test "token endpoint invalid_grant passes through as invalid_grant" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    WebMock.stub_request(:post, oidc_stub.token_endpoint)
           .to_return(status: 400, headers: json_headers, body: { error: "invalid_grant", error_description: "AADSTS70008 expired code" }.to_json)
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_failed :invalid_grant
    assert_not_includes last_response.body, "AADSTS70008"
  end

  test "token endpoint HTTP 500 without an OAuth error body passes through the gem's Unknown key" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    WebMock.stub_request(:post, oidc_stub.token_endpoint).to_return(status: 500, body: "boom")
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_failed :Unknown
  end

  test "token endpoint read timeout becomes timeout (the gem's key name)" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    WebMock.stub_request(:post, oidc_stub.token_endpoint).to_raise(Net::ReadTimeout)
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_failed :timeout
  end

  test "token endpoint connect timeout becomes failed_to_connect (Faraday reports it as a connection failure)" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    WebMock.stub_request(:post, oidc_stub.token_endpoint).to_timeout
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_failed :failed_to_connect
  end

  test "token endpoint connection failure becomes failed_to_connect (the gem's key name)" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    WebMock.stub_request(:post, oidc_stub.token_endpoint).to_raise(SocketError)
    get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]

    assert_failed :failed_to_connect
  end

  # ---- IdP error redirect (user cancelled) --------------------------------

  test "IdP access_denied redirect passes through as access_denied with the CallbackError reason" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    get "/auth/openid_connect/callback", error: "access_denied",
                                         error_description: "AADSTS65004: The user declined to consent",
                                         state: params["state"]

    error = assert_failed(:access_denied)
    assert_kind_of OmniAuth::Strategies::OpenIDConnect::CallbackError, error
    assert_equal "access_denied", error.error
    assert_equal "AADSTS65004: The user declined to consent", error.error_reason
    assert_not_includes last_response.body, "AADSTS65004"
  end

  test "IdP error redirect without state still passes through as the IdP error key" do
    post "/auth/openid_connect"
    get "/auth/openid_connect/callback", error: "access_denied", error_description: "cancelled"

    assert_failed :access_denied
  end

  # ---- what must NOT be swallowed -----------------------------------------

  test "a non-StandardError, non-listed Exception is not swallowed (callback phase)" do
    post "/auth/openid_connect"
    _location, params = authorize_params
    WebMock.stub_request(:post, oidc_stub.token_endpoint).to_raise(FatalStub)

    assert_raises(FatalStub) do
      get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]
    end
    assert_empty @fail_keys
  end

  test "a non-StandardError, non-listed Exception is not swallowed (request phase)" do
    WebMock.stub_request(:get, oidc_stub.discovery_url).to_raise(FatalStub)

    assert_raises(FatalStub) { post "/auth/openid_connect" }
    assert_empty @fail_keys
  end

  test "an error raised by the downstream app is not converted into an authentication failure" do
    app_error = Class.new(StandardError)
    options = strategy_options
    @app = Rack::Builder.new do
      use Rack::Session::Cookie, secret: SecureRandom.hex(64), same_site: :lax
      use EntraAuth::Strategy, options
      run ->(_env) { raise app_error, "controller bug" }
    end.to_app

    post "/auth/openid_connect"
    _location, params = authorize_params
    oidc_stub.token_response_id_token = oidc_stub.id_token(nonce: params["nonce"])

    assert_raises(app_error) do
      get "/auth/openid_connect/callback", code: "auth-code-1", state: params["state"]
    end
    assert_empty @fail_keys
  end

  # ---- happy path stays green ---------------------------------------------

  test "a valid sign-in is unaffected by the failure handling" do
    sign_in_with

    assert_equal 200, last_response.status
    assert_empty @fail_keys
    assert_not_nil @auth_results.last
  end
end
