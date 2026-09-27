require "test_helper"
require "open3"

# Task 5.2: session expiry through the REAL stack (Warden + Devise timeoutable
# + EntraAuth::AbsoluteTimeout + FailureApp + our /login page).
# Requirements 6.1, 6.2, 6.3, 6.4, 6.5 (6.6 wiring: one test at the end).
#
# Time is frozen with travel_to (no block: the whole request sequence that
# depends on time stays in one test, and ActiveSupport restores the real clock
# after each test). Sessions are started with Devise's sign_in helper (which
# fires Warden's :set_user event, recorded like :authentication by
# AbsoluteTimeout), except the "real sign-in" tests which use the real
# Strategy against the WebMock OidcProviderStub (no network).
#
# Devise semantics relied on: a session is idle-expired when
# last_request_at <= timeout_in.ago (so exactly the limit is ALREADY expired,
# one second before is valid). AbsoluteTimeout expires when
# now - login_at > absolute limit (exactly the limit is still valid).
# Every request through Devise refreshes last_request_at, never login_at.
class SessionExpiryTest < ActionDispatch::IntegrationTest
  include SessionsTestHelpers

  BASE = Time.utc(2030, 1, 15, 9, 0, 0)
  MARKER = "ProtectedMarker Kappa".freeze
  START = "/users/auth/openid_connect".freeze
  CALLBACK = "/users/auth/openid_connect/callback".freeze

  setup do
    @user = User.create!(tid: EntraAuth::Config.tenant_id, oid: SecureRandom.uuid, name: MARKER, email: "kappa@example.com")
    @idle = Devise.timeout_in
    @absolute = EntraAuth::Config.absolute_timeout
  end

  # --- helpers ---

  def at(time)
    travel_to(time)
  end

  def assert_protected_content
    assert_response :success
    assert_includes response.body, MARKER
  end

  def assert_no_protected_content
    assert_not_includes response.body.to_s, MARKER
    assert_not_includes response.body.to_s, I18n.t("home.index.title")
  end

  # Follows redirects (max 3 hops) asserting that no hop carries protected
  # content and that the chain ends on /login. Devise's timeout failure
  # redirects to the attempted path first (flash[:timedout] set) and the
  # re-issued request is then bounced to /login with the flash kept, so idle
  # expiry takes two hops; unauthenticated / absolute expiry take one.
  def follow_to_login
    hops = 0
    while response.redirect? && response.location != new_user_session_url
      assert_no_protected_content
      follow_redirect!
      hops += 1
      assert_operator hops, :<=, 3
    end
    assert_redirected_to new_user_session_url
    assert_no_protected_content
    follow_redirect!
    assert_response :success
  end

  # GET / must end on /login with the given expiry text and no protected content.
  def assert_expired_get(message_key)
    get "/"
    assert_response :redirect
    follow_to_login
    assert_includes response.body, ERB::Util.html_escape(I18n.t(message_key))
    assert_no_protected_content
  end

  def sign_in_at_base
    at BASE
    sign_in @user
    get "/"
    assert_protected_content
  end

  # --- (a) idle expiry (6.1, 6.3, 6.4) ---

  test "idle: a request after the idle timeout redirects to /login with the idle text and no protected content" do
    sign_in_at_base
    at BASE + @idle + 1.minute
    assert_expired_get "devise.failure.timeout"
    assert_not_equal I18n.t("devise.failure.timeout"), I18n.t("devise.failure.absolute_timeout")
  end

  test "idle: one second before the limit is still valid; exactly at the limit is expired (Devise: last_request_at <= timeout_in.ago)" do
    sign_in_at_base
    at BASE + @idle - 1.second
    get "/"
    assert_protected_content

    # That request refreshed last_request_at to (BASE + idle - 1s); measure from there.
    at BASE + @idle - 1.second + @idle
    assert_expired_get "devise.failure.timeout"
  end

  test "idle: without any request in between, exactly the idle limit after sign-in is expired" do
    sign_in_at_base
    at BASE + @idle
    assert_expired_get "devise.failure.timeout"
  end

  test "idle: activity keeps the session alive past the idle timeout, up to the absolute limit" do
    sign_in_at_base
    step = @idle - 1.minute
    now = BASE
    count = 0
    while now + step <= BASE + @absolute
      now += step
      at now
      get "/"
      assert_protected_content
      count += 1
    end
    assert_operator step * count, :>, @idle, "the loop must outlast the idle timeout"
    assert_operator now - BASE, :>, @idle
  end

  test "idle: the idle text is localized (ja) when the request runs in the ja locale" do
    sign_in_at_base
    at BASE + @idle + 1.minute
    ja = I18n.t("devise.failure.timeout", locale: :ja)
    assert_not_equal I18n.t("devise.failure.timeout", locale: :en), ja
    I18n.with_locale(:ja) do
      get "/"
      follow_to_login
      assert_includes response.body, ERB::Util.html_escape(ja)
    end
    assert_no_protected_content
  end

  # --- (b) absolute expiry (6.2, 6.3, 6.4) ---

  # Requests spaced under the idle limit up to (and including) `until_time`.
  def keep_busy_until(until_time, origin = BASE)
    step = @idle - 1.minute
    now = origin
    while now < until_time
      now = [ now + step, until_time ].min
      at now
      get "/"
      assert_protected_content
    end
  end

  test "absolute: busy session is still valid at the limit, expired one second after, with the absolute text" do
    sign_in_at_base
    keep_busy_until BASE + @absolute # exactly the limit: still valid
    at BASE + @absolute + 1.second
    assert_expired_get "devise.failure.absolute_timeout"
    assert_not_equal I18n.t("devise.failure.absolute_timeout"), I18n.t("devise.failure.timeout")
  end

  test "absolute: the limit is measured from sign-in; activity just before it does not extend it" do
    sign_in_at_base
    keep_busy_until BASE + @absolute - 1.second
    # activity happened 1 second before the limit; 2 seconds later it is over
    at BASE + @absolute + 1.second
    assert_expired_get "devise.failure.absolute_timeout"
  end

  # --- (c) re-sign-in resets the origin (6.5) ---

  test "re-sign-in after an absolute expiry starts a new absolute clock (Devise sign_in helper)" do
    sign_in_at_base
    keep_busy_until BASE + @absolute
    at BASE + @absolute + 1.second
    assert_expired_get "devise.failure.absolute_timeout"

    second = BASE + @absolute + 5.minutes
    at second
    sign_in @user
    get "/"
    assert_protected_content

    keep_busy_until second + @absolute - 1.minute, second
    assert_operator (Time.now - BASE), :>, @absolute, "more than the limit has passed since the FIRST sign-in"
    get "/"
    assert_protected_content

    at second + @absolute + 1.second
    assert_expired_get "devise.failure.absolute_timeout"
  end

  # --- real sign-in (AbsoluteTimeout on :authentication through the real Strategy) ---

  def real_sign_in
    saved = [ ActionController::Base.allow_forgery_protection, OmniAuth.config.test_mode ]
    OmniAuth.config.test_mode = false
    ActionController::Base.allow_forgery_protection = true
    get "/login"
    token = form_token(response.body)
    assert token.present?
    post START, params: { authenticity_token: token }
    assert_response :redirect
    query = Rack::Utils.parse_query(URI.parse(response.location).query)
    oidc_stub.token_response_id_token = oidc_stub.id_token(
      oid: @user.oid, name: MARKER, email: @user.email, nonce: query["nonce"]
    )
    get CALLBACK, params: { code: "fake-code", state: query["state"] }
    assert_response :redirect
    ActionController::Base.allow_forgery_protection = false
    get "/"
    assert_protected_content
  ensure
    ActionController::Base.allow_forgery_protection, OmniAuth.config.test_mode = saved
  end

  test "real sign-in records the origin: absolute expiry after the limit, and a real re-sign-in resets it" do
    install_oidc_provider_stub
    at BASE
    real_sign_in
    keep_busy_until BASE + @absolute
    at BASE + @absolute + 1.second
    assert_expired_get "devise.failure.absolute_timeout"

    second = BASE + @absolute + 10.minutes
    at second
    real_sign_in
    keep_busy_until second + @absolute - 1.minute, second
    assert_operator (Time.now - BASE), :>, @absolute
    get "/"
    assert_protected_content

    at second + @absolute + 1.second
    assert_expired_get "devise.failure.absolute_timeout"
  end

  # --- (d) expired requests never render protected content; no revival ---

  test "after an idle expiry the session is gone: later requests stay unauthenticated (no revival)" do
    sign_in_at_base
    at BASE + @idle + 1.minute
    assert_expired_get "devise.failure.timeout"
    # Even back inside what would have been a valid window, without signing in again:
    at BASE + @idle + 2.minutes
    get "/"
    assert_redirected_to new_user_session_url
    assert_no_protected_content
    follow_redirect!
    assert_includes response.body, ERB::Util.html_escape(I18n.t("devise.failure.unauthenticated"))
    assert_not_includes response.body, ERB::Util.html_escape(I18n.t("devise.failure.timeout"))
  end

  test "after an absolute expiry the session is gone: later requests stay unauthenticated (no revival)" do
    sign_in_at_base
    at BASE + @absolute + 1.minute
    assert_expired_get "devise.failure.absolute_timeout"
    at BASE + @absolute + 2.minutes
    get "/"
    assert_redirected_to new_user_session_url
    assert_no_protected_content
    at BASE + 1.minute # even a clock that goes back does not revive it
    get "/"
    assert_redirected_to new_user_session_url
  end

  test "non-GET request on an expired session (DELETE /logout, the only non-GET route) completes safely for both expiry kinds" do
    { "idle" => @idle + 1.minute, "absolute" => @absolute + 1.minute }.each do |kind, elapsed|
      sign_in_at_base
      at BASE + elapsed
      delete "/logout"
      assert_response :redirect, kind
      assert_no_protected_content
      follow_redirect! while response.redirect? && URI.parse(response.location).host == "www.example.com"
      get "/"
      assert_redirected_to new_user_session_url, kind
      assert_no_protected_content
      travel_back
    end
  end

  test "a POST to a protected path on an expired session does not render protected content" do
    # No non-GET protected route exists: the request is rejected either by
    # routing or by authentication, never with protected content.
    sign_in_at_base
    at BASE + @absolute + 1.minute
    post "/"
    assert_includes [ 302, 303, 404 ], response.status
    assert_no_protected_content
    get "/"
    assert_redirected_to new_user_session_url
    assert_no_protected_content
  end

  # --- (e) configurability wiring (6.6) ---

  test "the effective limits are the configured ones (Devise.timeout_in and the absolute limit)" do
    assert_equal EntraAuth::Config.idle_timeout, Devise.timeout_in
    assert_equal EntraAuth::Config.idle_timeout, User.timeout_in
    assert_predicate EntraAuth::AbsoluteTimeout, :installed?

    # The absolute limit effectively used equals Config.absolute_timeout.
    sign_in_at_base
    keep_busy_until BASE + @absolute
    at BASE + @absolute + 1.second
    assert_expired_get "devise.failure.absolute_timeout"
  end

  test "a boot with changed ENTRA_SESSION_* settings uses them for both limits" do
    env = SessionsTestHelpers::ENTRA_ENV_NAMES.to_h { |name| [ name, nil ] }
    env.merge!("DATABASE_URL" => nil, "RAILS_ENV" => "test",
               "ENTRA_SESSION_IDLE_MINUTES" => "7", "ENTRA_SESSION_ABSOLUTE_HOURS" => "3")
    script = 'puts "idle=#{Devise.timeout_in.to_i} abs=#{EntraAuth::Config.absolute_timeout.to_i}"'
    output, status = Open3.capture2e(env, "bin/rails", "runner", script, chdir: Rails.root.to_s)
    assert status.success?, output
    assert_includes output, "idle=#{7 * 60} abs=#{3 * 3600}"
  end
end
