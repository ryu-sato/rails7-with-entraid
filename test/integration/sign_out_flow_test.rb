require "test_helper"
require "minitest/mock"

# Task 5.3: sign-out through the REAL stack (Warden + Devise + SessionsController
# + EntraAuth::LogoutUrl). Sign-in uses the real Strategy against the WebMock
# OidcProviderStub (no OmniAuth test mode). The Entra logout URL is only
# inspected as a Location header, NEVER requested (no network).
# Requirements 7.1, 7.2, 7.3, 7.5, 7.6, 7.7 (7.4 sanity for /signed_out).
class SignOutFlowTest < ActionDispatch::IntegrationTest
  include SessionsTestHelpers

  START = "/users/auth/openid_connect".freeze
  CALLBACK = "/users/auth/openid_connect/callback".freeze
  HINT = "hint-for-signout-5-3".freeze
  MARKER = "SignOutMarker Omega".freeze

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

  # Real sign-in: /login -> POST start -> stubbed token endpoint -> callback.
  def real_sign_in(login_hint: nil)
    get "/login"
    assert_response :success
    post START, params: { authenticity_token: form_token(response.body) }
    assert_response :redirect
    query = Rack::Utils.parse_query(URI.parse(response.location).query)
    claims = { oid: @oid, name: MARKER, email: "omega@example.com", nonce: query["nonce"] }
    claims[:login_hint] = login_hint if login_hint
    oidc_stub.token_response_id_token = oidc_stub.id_token(**claims)
    get CALLBACK, params: { code: "code-5-3", state: query["state"] }
    assert_redirected_to root_url
  end

  # GET / (renders the sign-out button) and returns the CSRF token of the page.
  def page_token
    get "/"
    assert_response :success
    assert_includes response.body, MARKER
    token = meta_token(response.body)
    assert token.present?
    token
  end

  def session_cookie_name = Rails.application.config.session_options[:key]

  def assert_logged_out_at_login
    get "/"
    assert_redirected_to new_user_session_url
    assert_not_includes response.body.to_s, MARKER
  end

  def session_keys = request.session.to_h.keys

  # --- (a) full flow, redirect target ---

  test "sign-out after real sign-in redirects 303 to the exact Entra logout URL with logout_hint" do
    real_sign_in(login_hint: HINT)
    delete "/logout", params: { authenticity_token: page_token }
    assert_response :see_other
    assert_equal EntraAuth::LogoutUrl.build(logout_hint: HINT), response.location

    uri = URI.parse(response.location)
    assert_equal "login.microsoftonline.com", uri.host
    assert_equal "/#{EntraAuth::Config.tenant_id}/oauth2/v2.0/logout", uri.path
    params = Rack::Utils.parse_query(uri.query)
    assert_equal %w[logout_hint post_logout_redirect_uri], params.keys.sort
    assert_equal "#{EntraAuth::Config.app_base_url}/signed_out", params["post_logout_redirect_uri"]
    assert_equal HINT, params["logout_hint"]
    assert_not_includes response.location, "id_token_hint"
    assert_not_includes response.location, "client_id"
  end

  test "sign-out without login_hint in the ID token redirects without logout_hint" do
    real_sign_in
    delete "/logout", params: { authenticity_token: page_token }
    assert_response :see_other
    assert_equal EntraAuth::LogoutUrl.build(logout_hint: nil), response.location
    params = Rack::Utils.parse_query(URI.parse(response.location).query)
    assert_equal [ "post_logout_redirect_uri" ], params.keys
  end

  # --- (b) app session ends first, independent of Entra ---

  test "app session is already ended when the redirect is issued (redirect not followed)" do
    real_sign_in(login_hint: HINT)
    delete "/logout", params: { authenticity_token: page_token }
    assert_response :see_other
    assert_match(%r{\Ahttps://login\.microsoftonline\.com/}, response.location)
    # Not following the Entra URL: the very next app request is unauthenticated.
    assert_logged_out_at_login
  end

  test "Entra never returning to /signed_out leaves the app signed out" do
    real_sign_in(login_hint: HINT)
    delete "/logout", params: { authenticity_token: page_token }
    # Entra is unreachable / the user closes the tab: /signed_out is never requested.
    3.times do
      get "/"
      assert_redirected_to new_user_session_url
    end
    assert_not_includes response.body.to_s, MARKER
  end

  # --- (c) returning from Entra ---

  test "returning from Entra shows the public signed-out page with a login link" do
    real_sign_in(login_hint: HINT)
    delete "/logout", params: { authenticity_token: page_token }
    get "/signed_out"
    assert_response :success
    assert_select "h1", text: I18n.t("sessions.signed_out.title")
    assert_select "a[href=?]", new_user_session_path
    assert_not_includes response.body, MARKER
    assert_logged_out_at_login
  end

  # --- (d) not signed in ---

  test "sign-out without a session completes safely to the Entra URL without a hint" do
    with_forgery_protection do
      get "/login"
      delete "/logout", params: { authenticity_token: meta_token(response.body) }
    end
    assert_response :see_other
    assert_equal EntraAuth::LogoutUrl.build(logout_hint: nil), response.location
    assert_logged_out_at_login
  end

  test "sign-out after the session expired (idle) completes safely and leaves no session" do
    real_sign_in(login_hint: HINT)
    token = page_token
    travel_to((Devise.timeout_in + 60).seconds.from_now)
    delete "/logout", params: { authenticity_token: token }
    # Actual behavior: Devise's timeoutable hook fires on warden.authenticated?
    # inside #destroy, so the expired session is dropped by the FailureApp and
    # the user lands on /login (302, not the Entra URL). No 500, no session,
    # no stale hint sent anywhere. (Entra's own SSO session is not ended here.)
    assert_response :redirect
    assert_redirected_to new_user_session_url
    assert_not_includes response.location, "logout_hint"
    assert_logged_out_at_login
  end

  # --- (e) incomplete config ---

  test "sign-out with incomplete config still ends the app session and goes to /signed_out" do
    real_sign_in(login_hint: HINT)
    token = page_token
    with_entra_env("ENTRA_TENANT_ID" => nil, "ENTRA_APP_BASE_URL" => nil) do
      assert_nil EntraAuth::LogoutUrl.build(logout_hint: HINT)
      delete "/logout", params: { authenticity_token: token }
      assert_response :see_other
      assert_redirected_to signed_out_url
    end
    assert_logged_out_at_login
  end

  # --- (f) CSRF and verbs (7.7) ---

  test "DELETE /logout without an authenticity token is rejected and the user stays signed in" do
    real_sign_in(login_hint: HINT)
    delete "/logout"
    assert_response :unprocessable_entity
    page_token # still signed in and protected content served
  end

  test "DELETE /logout with a wrong authenticity token is rejected and the user stays signed in" do
    real_sign_in(login_hint: HINT)
    delete "/logout", params: { authenticity_token: "wrong-token" }
    assert_response :unprocessable_entity
    page_token
  end

  test "DELETE /logout with the page token succeeds" do
    real_sign_in(login_hint: HINT)
    delete "/logout", params: { authenticity_token: page_token }
    assert_response :see_other
  end

  test "only DELETE is routed for /logout" do
    verbs = Rails.application.routes.routes.select { |r| r.path.spec.to_s.start_with?("/logout") }
                 .map { |r| r.verb }
    assert_equal [ "DELETE" ], verbs
  end

  test "POST, GET, HEAD, PUT and PATCH to /logout are not accepted and keep the session" do
    real_sign_in(login_hint: HINT)
    token = page_token
    { get: {}, head: {}, post: { authenticity_token: token },
      put: { authenticity_token: token }, patch: { authenticity_token: token } }.each do |verb, params|
      send(verb, "/logout", params: params)
      assert_response :not_found, "#{verb.upcase} /logout must be a 404"
    end
    page_token # still signed in
  end

  # --- (g) UI smoke ---

  test "the layout sign-out button is a DELETE form to /logout" do
    real_sign_in
    page_token
    assert_select "form[action=?]", destroy_user_session_path do
      assert_select "input[name=_method][value=delete]"
    end
  end

  # --- (h) session fully cleared ---

  test "after sign-out the session holds no user or logout_hint and a new sign-in starts fresh" do
    real_sign_in(login_hint: HINT)
    page_token
    id_before = request.session.id.to_s
    assert session_keys.any? { |k| k.start_with?("warden.user.user") }, "precondition: signed in"

    delete "/logout", params: { authenticity_token: meta_token(response.body) }
    assert_response :see_other
    assert session_keys.none? { |k| k.start_with?("warden.user") }, session_keys.inspect
    assert_not_includes request.session.to_h.to_s, HINT
    assert_not_includes cookies[session_cookie_name].to_s, HINT

    get "/"
    assert_redirected_to new_user_session_url
    assert session_keys.none? { |k| k.start_with?("warden.user") }, session_keys.inspect

    real_sign_in # no login_hint this time: nothing may carry over
    page_token
    assert_not_equal id_before, request.session.id.to_s
    delete "/logout", params: { authenticity_token: meta_token(response.body) }
    assert_equal EntraAuth::LogoutUrl.build(logout_hint: nil), response.location
  end

  # --- security characterization ---

  test "cookie captured before sign-out - replay outcome (characterization)" do
    real_sign_in(login_hint: HINT)
    page_token
    captured = cookies[session_cookie_name]
    assert captured.present?

    delete "/logout", params: { authenticity_token: meta_token(response.body) }
    assert_response :see_other
    assert_logged_out_at_login

    cookies[session_cookie_name] = captured
    get "/"
    # Known limitation of stateless cookie sessions; bounded by idle/absolute
    # timeouts. The Cookie store keeps no server-side state and Devise runs
    # without database_authenticatable (no authenticatable_salt), so a copy of
    # the pre-sign-out cookie is still accepted. If server-side invalidation is
    # added later, this assertion must flip consciously.
    replay_accepted = response.successful? && response.body.include?(MARKER)
    assert replay_accepted, "replay outcome changed: status=#{response.status} location=#{response.location}"
  end
end
