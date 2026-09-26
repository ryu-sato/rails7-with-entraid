require "test_helper"
require "minitest/mock"

# Task 4.1: login page, sign-out and signed-out page.
# Requirements 1.1, 1.3, 5.5, 7.1-7.5, 7.7, 8.3.
class SessionsControllerTest < ActionDispatch::IntegrationTest
  include SessionsTestHelpers

  setup do
    @user = User.create!(tid: EntraAuth::Config.tenant_id, oid: SecureRandom.uuid, name: "Test", email: "t@example.com")
    @hint = "user@example.com"
  end

  # --- login page ---

  test "GET /login shows a POST form to the authorize path with turbo disabled" do
    with_forgery_protection do
      get "/login"
      assert_response :success
      form = Nokogiri::HTML(response.body).at_css("form[action='/users/auth/openid_connect']")
      assert form, "expected a form posting to the authorize path"
      assert_equal "post", form["method"].downcase
      assert_equal "false", form["data-turbo"]
      assert form.at_css("input[name=authenticity_token]"), "authenticity token field expected"
      assert_nil Nokogiri::HTML(response.body).at_css("a[href='/users/auth/openid_connect']")
    end
  end

  test "GET /login for a signed-in user redirects to the root and shows no form" do
    sign_in @user
    get "/login"
    assert_response :redirect
    assert_equal root_url, response.location
    assert_no_match(/openid_connect/, response.body)
  end

  test "GET /login with incomplete config renders a generic 503 and logs item names only" do
    log = nil
    with_entra_env("ENTRA_TENANT_ID" => nil, "ENTRA_CLIENT_SECRET" => "super-secret-value") do
      log = capture_rails_log { get "/login" }
      assert_response :service_unavailable
      assert_no_match(/super-secret-value|login\.microsoftonline|11111111|aaaaaaaa|tenant/i, response.body)
      assert_no_match(/openid_connect/, response.body)
    end
    assert_includes log, "tenant_id"
    assert_no_match(/super-secret-value|aaaaaaaa-bbbb|www\.example\.com/, log)
    assert_equal 1, log.lines.count { |l| l.include?("tenant_id") }
  end

  test "login page is public and 503 page needs no session" do
    with_entra_env("ENTRA_APP_BASE_URL" => nil) do
      get "/login"
      assert_response :service_unavailable
    end
  end

  # --- signed_out ---

  test "GET /signed_out is public and links to the login page" do
    get "/signed_out"
    assert_response :success
    assert Nokogiri::HTML(response.body).at_css("a[href='/login']"), "link to login expected"
  end

  test "GET /signed_out works while signed in as well" do
    sign_in @user
    get "/signed_out"
    assert_response :success
  end

  # --- destroy ---

  test "DELETE /logout redirects (303) to the Entra logout URL with the hint" do
    sign_in_with_hint(@user, @hint)
    delete "/logout"
    assert_response :see_other
    assert_equal EntraAuth::LogoutUrl.build(logout_hint: @hint), response.location
    assert_includes response.location, "logout_hint=user%40example.com"
  end

  test "DELETE /logout without a hint redirects to the URL without logout_hint" do
    sign_in_with_hint(@user)
    delete "/logout"
    assert_response :see_other
    assert_equal EntraAuth::LogoutUrl.build(logout_hint: nil), response.location
    assert_not_includes response.location, "logout_hint"
  end

  test "the app session is ended before the redirect URL is built and afterwards" do
    events = []
    entry = [ ->(_user, _auth, _opts) { events << :logout }, {} ]
    Warden::Manager._before_logout.push(entry)
    builder = lambda do |logout_hint:|
      events << :build
      "https://login.microsoftonline.com/x/oauth2/v2.0/logout?h=#{logout_hint}"
    end
    begin
      sign_in_with_hint(@user, @hint)
      EntraAuth::LogoutUrl.stub(:build, builder) { delete "/logout" }
    ensure
      Warden::Manager._before_logout.delete(entry)
    end
    assert_equal [ :logout, :build ], events.first(2)
    assert_response :see_other

    get "/login" # unauthenticated again: the login form, not a redirect
    assert_response :success
    assert Nokogiri::HTML(response.body).at_css("form[action='/users/auth/openid_connect']")
  end

  test "after DELETE /logout the warden user and session data are gone" do
    sign_in_with_hint(@user, @hint)
    get "/signed_out"
    assert_equal @user.id, request.env["warden"].user(:user).id
    delete "/logout"
    get "/signed_out"
    assert_nil request.env["warden"].user(:user)
    assert_not request.env["warden"].authenticated?(:user)
    assert_nil request.session["warden.user.user.key"]
    assert_nil request.session["warden.user.user.session"]
  end

  test "DELETE /logout when not signed in does not fail and still redirects" do
    delete "/logout"
    assert_response :see_other
    assert_equal EntraAuth::LogoutUrl.build(logout_hint: nil), response.location
  end

  test "DELETE /logout with incomplete config redirects to /signed_out after ending the session" do
    sign_in_with_hint(@user, @hint)
    with_entra_env("ENTRA_APP_BASE_URL" => nil) do
      delete "/logout"
      assert_response :see_other
      assert_equal "http://www.example.com/signed_out", response.location
      get "/signed_out"
      assert_not request.env["warden"].authenticated?(:user)
    end
  end

  test "GET /logout is not routable" do
    get "/logout"
    assert_response :not_found
  end

  test "DELETE /logout without an authenticity token is rejected and keeps the session" do
    with_forgery_protection do
      sign_in @user
      get "/signed_out"
      assert_response :success
      delete "/logout"
      assert_response :unprocessable_entity
      get "/login"
      assert_response :redirect
      assert_equal root_url, response.location
    end
  end

  test "DELETE /logout with a valid authenticity token signs out" do
    with_forgery_protection do
      sign_in_with_hint(@user, @hint)
      get "/signed_out"
      token = meta_token(response.body)
      assert token.present?
      delete "/logout", headers: { "X-CSRF-Token" => token }
      assert_response :see_other
      assert_equal EntraAuth::LogoutUrl.build(logout_hint: @hint), response.location
    end
  end

  # --- OmniAuth start through the real stack ---

  test "POST /users/auth/openid_connect with a valid token redirects to the stubbed authorize endpoint" do
    install_oidc_provider_stub
    with_forgery_protection do
      get "/login"
      token = form_token(response.body)
      assert token.present?
      post "/users/auth/openid_connect", params: { authenticity_token: token }
      assert_response :redirect
      assert response.location.start_with?(oidc_stub.authorization_endpoint), response.location
    end
  end

  test "GET /users/auth/openid_connect is not allowed" do
    install_oidc_provider_stub
    get "/users/auth/openid_connect"
    assert_response :not_found
  end

  test "POST /users/auth/openid_connect without a token is rejected" do
    install_oidc_provider_stub
    with_forgery_protection do
      # The token check fails inside OmniAuth (logged as InvalidAuthenticityToken)
      # and OmniAuth's on_failure hands over to Users::OmniauthCallbacksController
      # (task 4.2). Until that exists the hand-over raises NameError; afterwards it
      # redirects to the login page. Either way the flow must NOT reach Entra.
      begin
        post "/users/auth/openid_connect"
        assert_not response.location.to_s.start_with?(oidc_stub.authorization_endpoint)
      rescue NameError => e
        assert_match(/Users/, e.message)
      end
      assert_not_requested :get, oidc_stub.discovery_url
    end
  end
end
