require "test_helper"
require "minitest/mock"

# Task 5.1: the whole sign-in flow through the REAL stack, WITHOUT
# OmniAuth.config.test_mode: EntraAuth::Strategy really runs (discovery,
# state / nonce / PKCE, token exchange, ID token verification, tid check),
# followed by VerifiedIdentity, User, SignInGate and Devise sign_in.
# The IdP is the WebMock OidcProviderStub; the "authorize" redirect is only a
# Location header that is parsed, never followed. No real network.
# Requirements 1.2, 2.4, 2.5, 3.2, 3.3, 4.1, 4.2, 4.5, 5.2, 9.2, 9.3.
class SignInFlowTest < ActionDispatch::IntegrationTest
  START = "/users/auth/openid_connect".freeze
  CALLBACK = "/users/auth/openid_connect/callback".freeze
  SENTINEL_NAME = "SentinelName Zeta".freeze
  SENTINEL_EMAIL = "sentinel.zeta@example.com".freeze
  SENTINEL_CODE = "sentinel-auth-code-9f3".freeze

  setup do
    install_oidc_provider_stub
    @oid = SecureRandom.uuid
    @saved_forgery = ActionController::Base.allow_forgery_protection
    @saved_test_mode = OmniAuth.config.test_mode
    OmniAuth.config.test_mode = false
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @saved_forgery
    OmniAuth.config.test_mode = @saved_test_mode
  end

  # --- helpers ---

  def form_token(html)
    Nokogiri::HTML(html).at_css("form input[name=authenticity_token]")&.[]("value")
  end

  # Starts the flow from the login page. Returns { state:, nonce: } parsed from
  # the (never followed) authorization redirect.
  def start_flow
    get "/login"
    assert_response :success
    token = form_token(response.body)
    assert token.present?, "login page must carry an authenticity token"
    post START, params: { authenticity_token: token }
    assert_response :redirect
    assert response.location.start_with?(oidc_stub.authorization_endpoint), response.location
    query = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert query["state"].present?
    assert query["nonce"].present?
    { state: query["state"], nonce: query["nonce"] }
  end

  # Runs start + callback. claims are merged over the defaults; the nonce of
  # the ID token defaults to the one issued at the start.
  def complete_flow(claims: {}, callback_state: nil, nonce: nil)
    started = start_flow
    base = { oid: @oid, name: SENTINEL_NAME, email: SENTINEL_EMAIL, nonce: nonce || started[:nonce] }
    oidc_stub.token_response_id_token = oidc_stub.id_token(**base.merge(claims))
    get CALLBACK, params: { code: SENTINEL_CODE, state: callback_state || started[:state] }
  end

  def assert_signed_out_at_login(message: nil)
    assert_response :redirect
    assert_redirected_to new_user_session_url
    follow_redirect!
    assert_response :success
    assert_includes response.body, ERB::Util.html_escape(message) if message
    get "/"
    assert_redirected_to new_user_session_url
  end

  def with_log
    io = StringIO.new
    Rails.stub(:logger, ActiveSupport::Logger.new(io)) { yield }
    io.string
  end

  def assert_no_leak(*texts, extra: [])
    ([ SENTINEL_NAME, SENTINEL_EMAIL, SENTINEL_CODE, @oid ] + extra).each do |secret|
      texts.each { |text| assert_not_includes text.to_s, secret }
    end
  end

  # Failure through the real strategy: no session, /login, fixed text, no user.
  def assert_failure_flow(expected_key, **flow)
    log = with_log { complete_flow(**flow) }
    assert_signed_out_at_login(message: I18n.t("entra_authentication.failures.#{expected_key}"))
    assert_equal 0, User.count
    assert_no_leak(response.body, log)
    log
  end

  # --- success ---

  test "successful sign-in creates the user once, lands on root and is signed in" do
    assert_difference -> { User.count }, 1 do
      complete_flow
    end
    assert_response :see_other
    assert_redirected_to root_url
    follow_redirect!
    assert_response :success
    user = User.find_by!(oid: @oid)
    assert_equal OidcProviderStub::FAKE_TENANT_ID, user.tid
    assert_equal SENTINEL_NAME, user.name
    assert_equal SENTINEL_EMAIL, user.email
  end

  test "second sign-in with the same oid reuses the user and refreshes name and email" do
    complete_flow
    delete "/logout", params: { authenticity_token: meta_token_from(get_root) }
    assert_no_difference -> { User.count } do
      complete_flow(claims: { name: "Renamed Person", email: "renamed@example.com" })
    end
    assert_redirected_to root_url
    assert_equal 1, User.where(oid: @oid).count
    user = User.find_by!(oid: @oid)
    assert_equal "Renamed Person", user.name
    assert_equal "renamed@example.com", user.email
  end

  def get_root
    get "/"
    assert_response :success
    response.body
  end

  def meta_token_from(html)
    Nokogiri::HTML(html).at_css("meta[name=csrf-token]")&.[]("content")
  end

  test "login_hint from the ID token drives the Entra logout URL on sign-out" do
    hint = "hint-value-abc"
    complete_flow(claims: { login_hint: hint })
    token = meta_token_from(get_root)
    delete "/logout", params: { authenticity_token: token }
    assert_response :see_other
    expected = EntraAuth::LogoutUrl.build(logout_hint: hint)
    assert expected.present?
    assert_equal expected, response.location
    get "/"
    assert_redirected_to new_user_session_url
  end

  test "sign-out without a login_hint does not include a hint" do
    complete_flow
    token = meta_token_from(get_root)
    delete "/logout", params: { authenticity_token: token }
    assert_response :see_other
    assert_equal EntraAuth::LogoutUrl.build(logout_hint: nil), response.location
  end

  # --- return to the original page (5.2) ---

  test "sign-in returns to the originally requested page including its query" do
    get "/?foo=bar"
    assert_redirected_to new_user_session_url
    complete_flow
    assert_response :redirect
    assert_equal "http://www.example.com/?foo=bar", response.location
    follow_redirect!
    assert_response :success
  end

  # --- gate (9.2, 9.3, 4.5) ---

  test "gate accept: signed in and the gate's change is persisted" do
    EntraAuth::SignInGate.register(lambda { |_identity, user|
      user.update!(name: "gate-set")
      EntraAuth::SignInGate.accept
    })
    complete_flow
    assert_redirected_to root_url
    get "/"
    assert_response :success
    assert_equal "gate-set", User.find_by!(oid: @oid).name
  end

  test "gate reject: no session, gate message shown, gate's change and user record remain" do
    message = "拒否理由テスト"
    EntraAuth::SignInGate.register(lambda { |_identity, user|
      user.update!(name: "gate-set-on-reject")
      EntraAuth::SignInGate.reject(reason: :not_allowed, message: message)
    })
    complete_flow
    assert_signed_out_at_login(message: message)
    user = User.find_by!(oid: @oid)
    assert_equal "gate-set-on-reject", user.name
    assert_equal 1, User.count
  end

  test "gate that raises: no session and the generic message" do
    EntraAuth::SignInGate.register(->(_identity, _user) { raise "boom-secret-detail" })
    log = with_log { complete_flow }
    assert_signed_out_at_login(message: I18n.t("entra_authentication.failures.generic"))
    assert_no_leak(response.body, log, extra: [ "boom-secret-detail" ])
  end

  # --- failure paths through the real strategy (4.1, 4.2, 2.4, 2.5) ---

  test "user cancels at the IdP: cancelled text, no session, no user" do
    started = start_flow
    log = with_log do
      get CALLBACK, params: { error: "access_denied", error_description: "AADSTS-sentinel-desc cancelled",
                              state: started[:state] }
    end
    assert_signed_out_at_login(message: I18n.t("entra_authentication.failures.cancelled"))
    assert_equal 0, User.count
    # error_description arrives as a query parameter, so Rails' own request line
    # logs it (not filtered by filter_parameters; noted for 5.5). Our lines and
    # the page must not echo it.
    assert_no_leak(response.body, extra: [ "AADSTS-sentinel-desc" ])
    assert_no_leak(log.lines.grep(/\[Users::OmniauthCallbacks\]/).join, extra: [ "AADSTS-sentinel-desc" ])
  end

  test "tenant mismatch: failed text, no session, no user" do
    assert_failure_flow(:failed, claims: { tid: "99999999-8888-7777-6666-555555555555" })
  end

  test "missing oid claim: failed text, no session, no user" do
    assert_failure_flow(:failed, claims: { oid: nil })
  end

  test "invalid signature: failed text, no session, no user" do
    started = start_flow
    other = OidcProviderStub.new
    forged_key = OpenSSL::PKey::RSA.generate(2048)
    jwt = JSON::JWT.new(other.default_claims.merge(oid: @oid, name: SENTINEL_NAME, nonce: started[:nonce]))
    jwt.kid = other.kid
    oidc_stub.token_response_id_token = jwt.sign(forged_key, :RS256).to_s
    log = with_log { get CALLBACK, params: { code: SENTINEL_CODE, state: started[:state] } }
    assert_signed_out_at_login(message: I18n.t("entra_authentication.failures.failed"))
    assert_equal 0, User.count
    assert_no_leak(response.body, log)
  end

  test "wrong issuer: failed text, no session, no user" do
    assert_failure_flow(:failed, claims: { iss: "https://login.microsoftonline.com/evil/v2.0" })
  end

  test "wrong audience: failed text, no session, no user" do
    assert_failure_flow(:failed, claims: { aud: "some-other-client" })
  end

  test "expired ID token: failed text, no session, no user" do
    past = Time.now.to_i - 7200
    assert_failure_flow(:failed, claims: { iat: past - 60, nbf: past - 60, exp: past })
  end

  test "wrong nonce: failed text, no session, no user" do
    assert_failure_flow(:failed, nonce: "not-the-issued-nonce")
  end

  test "state mismatch: failed text, no session, no user" do
    assert_failure_flow(:failed, callback_state: "forged-state")
  end

  test "token endpoint error: failed text, no session, no user" do
    started = start_flow
    WebMock.stub_request(:post, oidc_stub.token_endpoint)
           .to_return(status: 400, headers: { "Content-Type" => "application/json" },
                      body: { error: "invalid_grant", error_description: "AADSTS-sentinel-grant" }.to_json)
    log = with_log { get CALLBACK, params: { code: SENTINEL_CODE, state: started[:state] } }
    assert_signed_out_at_login(message: I18n.t("entra_authentication.failures.failed"))
    assert_equal 0, User.count
    assert_no_leak(response.body, log, extra: [ "AADSTS-sentinel-grant" ])
  end
end
