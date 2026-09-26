require "test_helper"

# Task 4.3: every action requires sign-in by default; public pages are explicit
# opt-outs. Requirements 1.5, 5.1-5.5, 7.6. No network: OmniAuth test_mode mocks.
class AccessProtectionTest < ActionDispatch::IntegrationTest
  CALLBACK = "/users/auth/openid_connect/callback".freeze
  START = "/users/auth/openid_connect".freeze

  # Explicit PUBLIC allowlist (GET paths reachable while signed out).
  # Out of scope: /up, /service-worker, /manifest are served by Rails::HealthController /
  # Rails::PwaController (ActionController::Base, not ApplicationController).
  PUBLIC_PATHS = [ "/login", "/signed_out", CALLBACK ].freeze

  setup do
    OmniAuth.config.test_mode = true
    @oid = SecureRandom.uuid
  end

  teardown do
    Rails.application.reload_routes! if @routes_modified
  end

  def mock_callback_identity
    OmniAuth.config.mock_auth[:openid_connect] = OmniAuth::AuthHash.new(
      provider: "openid_connect", uid: @oid,
      info: { name: "Taro Yamada", email: "taro@example.com" },
      credentials: { token: "x", id_token: "y" },
      extra: { raw_info: { "oid" => @oid, "tid" => EntraAuth::Config.tenant_id, "name" => "Taro Yamada",
                           "email" => "taro@example.com", "login_hint" => "h@example.com" } }
    )
  end

  test "unauthenticated top page redirects to /login and returns no content" do
    get "/"
    assert_redirected_to new_user_session_url
    assert_not_includes response.body, "Taro"
    assert_not_includes response.body, I18n.t("home.index.title")
  end

  test "the originally requested path with query is restored after sign-in" do
    get "/?foo=bar"
    assert_redirected_to new_user_session_url
    mock_callback_identity
    get CALLBACK
    assert_response :redirect
    assert_equal "http://www.example.com/?foo=bar", response.location
    follow_redirect!
    assert_response :success
  end

  test "without a remembered location sign-in lands on the root" do
    mock_callback_identity
    get CALLBACK
    assert_equal root_url, response.location
  end

  test "public pages are reachable while signed out" do
    get "/login"
    assert_response :success
    get "/signed_out"
    assert_response :success
    mock_callback_identity
    get CALLBACK
    assert_response :redirect
    assert_equal root_url, response.location
  end

  test "the OmniAuth failure path is reachable while signed out" do
    OmniAuth.config.mock_auth[:openid_connect] = :access_denied
    get CALLBACK
    assert_redirected_to new_user_session_url
    assert_not_equal 401, response.status
  end

  test "the POST sign-in start reaches the OmniAuth middleware while signed out" do
    post START
    assert_response :redirect
    assert_equal CALLBACK, URI(response.location).path
  end

  test "sign-out works while signed out and public /signed_out stays public" do
    delete destroy_user_session_path
    assert_response :redirect
    assert_no_match %r{/login\z}, response.location.to_s
  end

  test "ApplicationController registers authenticate_user! for every action" do
    filters = ApplicationController._process_action_callbacks.select { |c| c.kind == :before && c.filter == :authenticate_user! }
    assert_equal 1, filters.size
  end

  test "every routable GET page of an ApplicationController controller is protected unless allowlisted" do
    checked = []
    Rails.application.routes.routes.each do |route|
      next unless route.verb.to_s.include?("GET")
      controller = route.defaults[:controller]
      next if controller.blank?
      klass = "#{controller}_controller".camelize.safe_constantize
      next unless klass && klass <= ApplicationController
      path = route.path.spec.to_s.sub("(.:format)", "")
      next if path.include?(":") || path.include?("*")

      get path
      if PUBLIC_PATHS.include?(path)
        assert_not_equal new_user_session_url, response.location, "#{path} is public but redirected to login" if path == "/login"
      else
        assert_redirected_to new_user_session_url, "#{path} (#{controller}) must require sign-in"
      end
      checked << path
      reset!
      OmniAuth.config.test_mode = true
    end
    assert_includes checked, "/"
    assert_includes checked, "/login"
  end

  test "an expired or missing session never renders protected content" do
    user = User.create!(tid: EntraAuth::Config.tenant_id, oid: @oid, name: "Taro Yamada")
    sign_in user
    get root_path
    assert_response :success
    logout
    get root_path
    assert_redirected_to new_user_session_url
    assert_not_includes response.body, "Taro Yamada"
  end

  # --- documenting the opt-out mechanism (5.3, 5.4) ---

  class ProbeProtectedController < ApplicationController
    def index = render(plain: "protected-content")
  end

  class ProbePublicController < ApplicationController
    skip_before_action :authenticate_user!
    def index = render(plain: "public-content")
  end

  def draw_probe_routes
    @routes_modified = true
    Rails.application.routes.disable_clear_and_finalize = true
    Rails.application.routes.draw do
      get "probe_protected", to: "access_protection_test/probe_protected#index"
      get "probe_public", to: "access_protection_test/probe_public#index"
    end
  ensure
    Rails.application.routes.disable_clear_and_finalize = false
  end

  test "a new controller is protected by default and public only with an explicit skip" do
    draw_probe_routes
    get "/probe_protected"
    assert_redirected_to new_user_session_url
    assert_not_includes response.body, "protected-content"
    get "/probe_public"
    assert_response :success
    assert_equal "public-content", response.body
  end
end
