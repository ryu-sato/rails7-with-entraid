require "test_helper"

# Task 5.4: access protection and the restrictions on starting sign-in, through
# the REAL stack (real EntraAuth::Strategy, real CSRF check, WebMock IdP; the
# authorize redirect is only parsed, never followed). Config failures (8.3).
# Complements AccessProtectionTest (4.3) and SessionsControllerTest (4.1).
# Requirements 1.3, 5.1, 5.3, 5.4, 5.5, 8.3.
class AccessControlFlowTest < ActionDispatch::IntegrationTest
  include SessionsTestHelpers

  START = "/users/auth/openid_connect".freeze
  CALLBACK = "/users/auth/openid_connect/callback".freeze
  FAILED = -> { I18n.t("entra_authentication.failures.failed") }

  setup do
    install_oidc_provider_stub
    @saved_forgery = ActionController::Base.allow_forgery_protection
    @saved_test_mode = OmniAuth.config.test_mode
    OmniAuth.config.test_mode = false
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @saved_forgery
    OmniAuth.config.test_mode = @saved_test_mode
  end

  def login_token
    get "/login"
    assert_response :success
    token = form_token(response.body)
    assert token.present?
    token
  end

  def assert_start_rejected_to_login
    assert_response :redirect
    assert_equal new_user_session_url, response.location
    assert_equal FAILED.call, flash[:alert]
    assert_not_requested :any, /login\.microsoftonline\.com/
  end

  # --- (a) default protection (5.1, 5.3) ---

  test "signed out GET / redirects to /login on every hop and never carries protected content" do
    get "/"
    assert_redirected_to new_user_session_url
    assert_not_includes response.body, I18n.t("home.index.title")
    follow_redirect!
    assert_response :success
    assert_not_includes response.body, I18n.t("home.index.title")
  end

  test "a signed-in session is served the protected page" do
    user = User.create!(tid: EntraAuth::Config.tenant_id, oid: SecureRandom.uuid, name: "Hanako Zeta")
    sign_in user
    get "/"
    assert_response :success
    assert_includes response.body, I18n.t("home.index.title")
  end

  # --- (b) explicit public pages (5.4, 5.5) ---

  test "login, signed_out, the start POST and the failure callback are reachable while signed out" do
    get "/login"
    assert_response :success
    get "/signed_out"
    assert_response :success
    post START, params: { authenticity_token: login_token }
    assert_response :redirect
    assert response.location.start_with?(oidc_stub.authorization_endpoint)
    get CALLBACK, params: { error: "access_denied" }
    assert_response :redirect
    assert_equal new_user_session_url, response.location
  end

  # --- (c) sign-in start restrictions (1.3) ---

  test "POST start with the real token redirects to the stubbed authorize endpoint with PKCE, state and nonce" do
    post START, params: { authenticity_token: login_token }
    assert_response :redirect
    uri = URI.parse(response.location)
    expected = URI.parse(oidc_stub.authorization_endpoint)
    assert_equal [ expected.host, expected.path ], [ uri.host, uri.path ]
    q = Rack::Utils.parse_query(uri.query)
    assert q["state"].present?
    assert q["nonce"].present?
    assert q["code_challenge"].present?
    assert_equal "S256", q["code_challenge_method"]
    assert_equal "code", q["response_type"]
    assert_equal EntraAuth::Config.client_id, q["client_id"]
    assert_equal EntraAuth::Config.redirect_uri, q["redirect_uri"]
    assert_includes q["scope"].split, "openid"
  end

  test "the login page offers no plain link to the start path, only a POST form" do
    get "/login"
    doc = Nokogiri::HTML(response.body)
    assert_empty doc.css("a").select { |a| a["href"].to_s.include?("openid_connect") }
    assert_equal "post", doc.at_css("form[action='#{START}']")["method"].downcase
  end

  test "GET, HEAD, PUT, PATCH and DELETE on the start path are not accepted and never reach the IdP" do
    token = login_token
    get START
    assert_response :not_found
    head START
    assert_response :not_found
    %i[put patch delete].each do |verb|
      send(verb, START, params: { authenticity_token: token })
      assert_response :not_found, "#{verb} must not start sign-in"
    end
    assert_not_requested :any, /login\.microsoftonline\.com/
  end

  test "POST start without a token is sent back to /login with the fixed message and no IdP request" do
    post START
    assert_start_rejected_to_login
  end

  test "POST start with a wrong token is rejected the same way" do
    login_token
    post START, params: { authenticity_token: "not-the-real-token" }
    assert_start_rejected_to_login
  end

  test "a token issued to another session (cross-site style) cannot start sign-in" do
    foreign_token = login_token
    reset! # new cookie jar: a different session
    ActionController::Base.allow_forgery_protection = true
    OmniAuth.config.test_mode = false
    get "/login" # own session exists, but the token comes from elsewhere
    post START, params: { authenticity_token: foreign_token }
    assert_start_rejected_to_login
  end

  # --- (d) configuration failure (8.3) ---

  CONFIG_CASES = {
    "tenant_id unset" => [ { "ENTRA_TENANT_ID" => nil }, "tenant_id" ],
    "client_id unset" => [ { "ENTRA_CLIENT_ID" => nil }, "client_id" ],
    "client_secret unset" => [ { "ENTRA_CLIENT_SECRET" => nil }, "client_secret" ],
    "app_base_url unset" => [ { "ENTRA_APP_BASE_URL" => nil }, "app_base_url" ],
    "tenant common" => [ { "ENTRA_TENANT_ID" => "common" }, "tenant_id" ],
    "non-http app_base_url" => [ { "ENTRA_APP_BASE_URL" => "ftp://secret-host.example.org" }, "app_base_url" ]
  }.freeze

  CONFIG_CASES.each do |label, (env, item)|
    test "config failure (#{label}): /login is a generic 503 and the log names only the item" do
      log = nil
      with_entra_env({ "ENTRA_CLIENT_SECRET" => "sentinel-secret-42" }.merge(env)) do
        log = capture_rails_log { get "/login" }
        assert_response :service_unavailable
        assert_includes response.body, I18n.t("sessions.unavailable.title")
        assert_no_match(/openid_connect|sentinel-secret-42|secret-host|11111111|aaaaaaaa|microsoftonline/, response.body)
        assert_no_match(/sentinel-secret-42|secret-host|11111111|aaaaaaaa/, response.headers.to_h.values.join(" "))
      end
      warning = log.lines.grep(/configuration is invalid/).join
      assert_includes warning, item
      assert_no_match(/sentinel-secret-42|secret-host|11111111|aaaaaaaa|common\b.*tenant/, log)
    end
  end

  # Incomplete config: the setup hook leaves the missing value nil. Observed
  # behaviour (see CONCERNS of task 5.4): with issuer nil the gem tries WebFinger
  # discovery against a bogus host ("https"), never Entra ID. We stub that
  # lookup as a network failure (SocketError) so the test stays hermetic.
  test "config failure: the start POST fails safely back to /login and never contacts Entra ID" do
    token = login_token
    stub_request(:get, %r{\Ahttps://https/\.well-known/webfinger}).to_raise(SocketError.new("getaddrinfo failed"))
    with_entra_env("ENTRA_TENANT_ID" => nil) do
      post START, params: { authenticity_token: token }
      assert_start_rejected_to_login
    end
  end

  test "after the configuration is restored /login renders the form again" do
    with_entra_env("ENTRA_CLIENT_ID" => nil) do
      get "/login"
      assert_response :service_unavailable
    end
    get "/login"
    assert_response :success
    assert Nokogiri::HTML(response.body).at_css("form[action='#{START}']")
  end
end
