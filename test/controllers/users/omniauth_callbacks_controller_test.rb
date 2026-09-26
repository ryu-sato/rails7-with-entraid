require "test_helper"

# Task 4.2: OIDC callback (sign-in completion) and failure handling.
# Requirements 1.2, 2.4, 2.6, 4.1-4.5, 5.5, 9.2, 9.3.
# All OmniAuth interaction uses test_mode mocks: no network.
class UsersOmniauthCallbacksControllerTest < ActionDispatch::IntegrationTest
  include SessionsTestHelpers

  CALLBACK = "/users/auth/openid_connect/callback".freeze
  SENTINEL_ACCESS = "SENTINEL-ACCESS-TOKEN-4f9a".freeze
  SENTINEL_ID_TOKEN = "SENTINEL-RAW-ID-TOKEN-7c21".freeze
  LEAKY_MESSAGE = "LEAKY-EXCEPTION-MESSAGE-91b3".freeze

  setup do
    OmniAuth.config.test_mode = true
    @oid = SecureRandom.uuid
  end

  # --- helpers ---

  def mock_identity(oid: @oid, tid: EntraAuth::Config.tenant_id, name: "Taro Yamada",
                    email: "taro@example.com", login_hint: "taro-hint@example.com", **extra)
    raw = { "oid" => oid, "tid" => tid, "name" => name, "email" => email, "login_hint" => login_hint }.merge(extra.transform_keys(&:to_s))
    raw.compact!
    OmniAuth::AuthHash.new(
      provider: "openid_connect", uid: oid.to_s,
      info: { name: name, email: email },
      credentials: { token: SENTINEL_ACCESS, id_token: SENTINEL_ID_TOKEN, refresh_token: "SENTINEL-REFRESH" },
      extra: { raw_info: raw }
    )
  end

  def sign_in_via_callback(auth = mock_identity)
    OmniAuth.config.mock_auth[:openid_connect] = auth
    get CALLBACK
  end

  def session_data(key)
    request.session["warden.user.user.session"]&.[](key)
  end

  def signed_in_now?
    get "/login"
    response.redirect?
  end

  def fixed(key) = I18n.t("entra_authentication.failures.#{key}")

  def assert_no_sentinels(*texts)
    texts.each do |text|
      [ SENTINEL_ACCESS, SENTINEL_ID_TOKEN, "SENTINEL-REFRESH", LEAKY_MESSAGE ].each do |s|
        assert_not_includes text.to_s, s
      end
    end
  end

  # Makes the mocked callback fail through OmniAuth's fail! with a real exception.
  def with_failing_callback(key, exception)
    original = EntraAuth::Strategy.instance_method(:mock_callback_call)
    EntraAuth::Strategy.send(:define_method, :mock_callback_call) { fail!(key, exception) }
    yield
  ensure
    EntraAuth::Strategy.send(:define_method, :mock_callback_call, original)
  end

  # --- accepted sign-in ---

  test "accepted sign-in creates the user, starts a session and redirects to the root" do
    assert_difference -> { User.count }, 1 do
      sign_in_via_callback
    end
    assert_response :redirect
    assert_equal root_url, response.location
    user = User.find_by!(tid: EntraAuth::Config.tenant_id, oid: @oid)
    assert_equal "Taro Yamada", user.name
    assert signed_in_now?, "expected a signed-in session"
    assert_equal user.id, request.env["warden"].user(:user).id
  end

  test "a second sign-in of the same identity does not duplicate the user and refreshes name/email" do
    sign_in_via_callback
    delete "/logout"
    assert_no_difference -> { User.count } do
      sign_in_via_callback(mock_identity(name: "Taro Renamed", email: "new@example.com"))
    end
    user = User.find_by!(oid: @oid)
    assert_equal "Taro Renamed", user.name
    assert_equal "new@example.com", user.email
    assert_equal 1, User.where(oid: @oid).count
  end

  test "the session id is renewed by sign-in (session fixation)" do
    Warden.on_next_request { |proxy| proxy.raw_session["planted"] = "1" }
    get "/login"
    get "/login"
    before_id = request.session.id.to_s
    assert before_id.present?

    sign_in_via_callback
    get "/login" # a new request reads the (renewed) id from the cookie
    after_id = request.session.id.to_s
    assert after_id.present?
    assert_not_equal before_id, after_id
  end

  test "the sign-in event records login_at" do
    freeze = Time.zone.parse("2026-03-01 10:00:00")
    travel_to(freeze) do
      sign_in_via_callback
      get "/login"
      assert_equal freeze.to_i, session_data("login_at")
    end
  end

  test "logout_hint is stored and used by the following sign-out" do
    sign_in_via_callback(mock_identity(login_hint: "taro-hint@example.com"))
    get "/login"
    assert_equal "taro-hint@example.com", session_data("logout_hint")
    delete "/logout"
    assert_response :see_other
    assert_equal EntraAuth::LogoutUrl.build(logout_hint: "taro-hint@example.com"), response.location
    assert_includes response.location, "logout_hint=taro-hint%40example.com"
  end

  test "without login_hint nothing is stored and sign-out adds no logout_hint" do
    sign_in_via_callback(mock_identity(login_hint: nil))
    get "/login"
    assert_nil session_data("logout_hint")
    delete "/logout"
    assert_response :see_other
    assert_not_includes response.location, "logout_hint"
  end

  test "a stored location is honored after sign-in" do
    Warden.on_next_request { |proxy| proxy.raw_session["user_return_to"] = "/some/page" }
    get "/login"
    sign_in_via_callback
    assert_response :redirect
    assert_equal "http://www.example.com/some/page", response.location
  end

  test "with no gates registered sign-in is accepted" do
    sign_in_via_callback
    assert signed_in_now?
  end

  test "the callback is reachable without a session (public entry point)" do
    sign_in_via_callback
    assert_response :redirect
    assert_not_equal new_user_session_url, response.location
  end

  test "access token and raw ID token are never read, stored, logged or shown" do
    auth = mock_identity
    auth.define_singleton_method(:credentials) { raise "credentials must never be read" }
    log = capture_rails_log { sign_in_via_callback(auth) }
    assert_response :redirect
    assert signed_in_now?
    assert_no_sentinels(
      log, response.body, flash.to_h.to_s, request.session.to_h.to_s,
      User.all.map(&:attributes).to_s, response.headers.to_h.to_s, cookies.to_hash.to_s
    )
  end

  test "sentinel credentials do not appear anywhere on a failed sign-in either" do
    auth = mock_identity(tid: SecureRandom.uuid)
    log = capture_rails_log { sign_in_via_callback(auth) }
    assert_no_sentinels(log, response.body, flash.to_h.to_s, request.session.to_h.to_s, User.all.map(&:attributes).to_s)
  end

  # --- VerifiedIdentity::Invalid ---

  test "a tenant mismatch starts no session, shows the fixed failed message and logs the reason only" do
    other_tid = SecureRandom.uuid
    log = capture_rails_log { sign_in_via_callback(mock_identity(tid: other_tid)) }
    assert_response :redirect
    assert_equal new_user_session_url, response.location
    assert_equal fixed(:failed), flash[:alert]
    assert_includes log, "tenant_mismatch"
    assert_not_includes log, other_tid
    assert_not_includes log, @oid
    assert_not signed_in_now?
    assert_equal 0, User.where(oid: @oid).count
  end

  test "a missing oid starts no session and creates no user" do
    log = nil
    assert_no_difference -> { User.count } do
      log = capture_rails_log { sign_in_via_callback(mock_identity(oid: nil)) }
    end
    assert_equal new_user_session_url, response.location
    assert_equal fixed(:failed), flash[:alert]
    assert_includes log, "missing_claims"
    assert_not signed_in_now?
  end

  test "an auth hash without raw_info is a failure, not an exception" do
    sign_in_via_callback(OmniAuth::AuthHash.new(provider: "openid_connect", uid: "x"))
    assert_equal new_user_session_url, response.location
    assert_equal fixed(:failed), flash[:alert]
    assert_not signed_in_now?
  end

  # --- gate ---

  test "a gate rejection starts no session and shows the gate message; the user record stays" do
    EntraAuth::SignInGate.register(lambda { |_identity, _user|
      EntraAuth::SignInGate.reject(reason: :no_role, message: "You have no role yet.")
    })
    log = capture_rails_log { sign_in_via_callback }
    assert_response :redirect
    assert_equal new_user_session_url, response.location
    assert_equal "You have no role yet.", flash[:alert]
    assert_includes log, "no_role"
    assert_not_includes log, "taro@example.com"
    assert_not_includes log, @oid
    assert_equal 1, User.where(oid: @oid).count
    assert_not signed_in_now?
  end

  test "a change persisted by the gate remains after rejection (controller neither saves nor rolls back)" do
    EntraAuth::SignInGate.register(lambda { |_identity, user|
      user.update!(name: "Set By Gate")
      EntraAuth::SignInGate.reject(reason: :no_role, message: "nope")
    })
    sign_in_via_callback
    assert_equal "Set By Gate", User.find_by!(oid: @oid).name
    assert_not signed_in_now?
  end

  test "a persisting gate that accepts leads to sign-in and its change stays" do
    EntraAuth::SignInGate.register(lambda { |_identity, user|
      user.update!(name: "Accepted Name")
      EntraAuth::SignInGate.accept
    })
    sign_in_via_callback
    assert_equal "Accepted Name", User.find_by!(oid: @oid).name
    assert signed_in_now?
  end

  test "the gate receives the normalized identity and the persisted user" do
    seen = nil
    EntraAuth::SignInGate.register(lambda { |identity, user|
      seen = [ identity, user ]
      EntraAuth::SignInGate.accept
    })
    sign_in_via_callback(mock_identity(oid: @oid.upcase))
    assert_kind_of EntraAuth::VerifiedIdentity, seen[0]
    assert seen[1].persisted?
    assert_equal @oid.downcase, seen[0].oid
  end

  test "a raising gate starts no session and shows the generic message without its exception text" do
    EntraAuth::SignInGate.register(->(_i, _u) { raise LEAKY_MESSAGE })
    log = capture_rails_log { sign_in_via_callback }
    assert_equal new_user_session_url, response.location
    assert_equal I18n.t("entra_authentication.failures.generic"), flash[:alert]
    assert_no_sentinels(log, flash.to_h.to_s, response.body)
    assert_not signed_in_now?
  end

  # --- failure action ---

  test "access_denied (cancel) redirects to the login page with the cancelled message" do
    OmniAuth.config.mock_auth[:openid_connect] = :access_denied
    log = capture_rails_log { get CALLBACK }
    assert_response :redirect
    assert_equal new_user_session_url, response.location
    assert_equal fixed(:cancelled), flash[:alert]
    assert_includes log, "access_denied"
    assert_equal 1, log.lines.count { |l| l.include?("access_denied") }
    assert_not signed_in_now?
  end

  test "other failure keys show the failed message" do
    %i[invalid_credentials invalid_id_token csrf_detected timeout].each do |key|
      OmniAuth.config.mock_auth[:openid_connect] = key
      log = capture_rails_log { get CALLBACK }
      assert_equal new_user_session_url, response.location, key
      assert_equal fixed(:failed), flash[:alert], key
      assert_includes log, key.to_s
    end
  end

  test "an unknown failure key shows the failed message" do
    OmniAuth.config.mock_auth[:openid_connect] = :something_never_seen
    get CALLBACK
    assert_equal new_user_session_url, response.location
    assert_equal fixed(:failed), flash[:alert]
  end

  test "the failure log has the key and the exception class only, never the message" do
    with_failing_callback(:invalid_id_token, ArgumentError.new(LEAKY_MESSAGE)) do
      log = capture_rails_log { get CALLBACK }
      assert_equal new_user_session_url, response.location
      assert_equal fixed(:failed), flash[:alert]
      assert_includes log, "invalid_id_token"
      assert_includes log, "ArgumentError"
      assert_no_sentinels(log, flash.to_h.to_s, response.body)
      assert_equal 1, log.lines.count { |l| l.include?("ArgumentError") }
    end
  end

  test "a failure with an exception and access_denied key is a cancel" do
    with_failing_callback(:access_denied, RuntimeError.new(LEAKY_MESSAGE)) do
      get CALLBACK
      assert_equal fixed(:cancelled), flash[:alert]
      assert_no_sentinels(flash.to_h.to_s, response.body)
    end
  end

  test "the failure message is fixed and free of tokens or exception text" do
    OmniAuth.config.mock_auth[:openid_connect] = :invalid_credentials
    get CALLBACK
    assert_no_sentinels(flash.to_h.to_s, response.body)
    assert_not signed_in_now?
  end
end
