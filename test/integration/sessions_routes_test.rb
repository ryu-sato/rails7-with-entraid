require "test_helper"

# Task 4.1: routes owned by this task. Requirements 1.1, 1.3, 5.5, 7.7.
class SessionsRoutesTest < ActionDispatch::IntegrationTest
  def route_table
    Rails.application.routes.routes.map do |r|
      [ r.verb, r.path.spec.to_s.sub("(.:format)", ""), r.defaults[:controller], r.defaults[:action] ]
    end
  end

  test "OmniAuth start and callback routes exist under /users/auth" do
    assert_includes route_table, [ "POST", "/users/auth/openid_connect", "users/omniauth_callbacks", "passthru" ]
    assert_includes route_table, [ "GET|POST", "/users/auth/openid_connect/callback", "users/omniauth_callbacks", "openid_connect" ]
    assert_equal "/users/auth/openid_connect", user_openid_connect_omniauth_authorize_path
  end

  test "the OmniAuth path helper equals the start path" do
    assert_equal "/users/auth/openid_connect", Rails.application.routes.url_helpers.user_openid_connect_omniauth_authorize_path
  end

  test "callback route path equals the redirect_uri path of Config" do
    assert_equal "/users/auth/openid_connect/callback", URI(EntraAuth::Config.redirect_uri).path
    assert_equal "/users/auth/openid_connect/callback", user_openid_connect_omniauth_callback_path
  end

  test "no Devise sessions or registrations routes are generated" do
    paths = route_table.map { |_, path, _, _| path }
    refute(paths.any? { |p| p.start_with?("/users/sign_in", "/users/sign_out", "/users/sign_up", "/users/password", "/users/edit") })
    controllers = route_table.map { |_, _, c, _| c }
    refute_includes controllers, "devise/sessions"
    refute_includes controllers, "devise/registrations"
  end

  test "login, logout and signed_out routes carry the Devise names" do
    assert_equal "/login", new_user_session_path
    assert_equal "/logout", destroy_user_session_path
    assert_equal "/signed_out", signed_out_path
    assert_includes route_table, [ "GET", "/login", "sessions", "new" ]
    assert_includes route_table, [ "DELETE", "/logout", "sessions", "destroy" ]
    assert_includes route_table, [ "GET", "/signed_out", "sessions", "signed_out" ]
    assert_respond_to self, :new_user_session_url
  end

  test "root route points to home#index and logout is not routable via GET" do
    assert_includes route_table, [ "GET", "/", "home", "index" ]
    assert_equal "/", root_path
    refute route_table.any? { |verb, path, _, _| path == "/logout" && verb != "DELETE" }
  end

  test "Devise failure app redirects unauthenticated requests to the login page" do
    env = Rack::MockRequest.env_for("http://www.example.com/x", "HTTP_ACCEPT" => "text/html")
    env["warden.options"] = { scope: :user, action: "unauthenticated" }
    env["warden"] = Warden::Proxy.new(env, Warden::Manager.new(nil))
    status, headers, = Devise::FailureApp.call(env)
    assert_equal 302, status
    assert_equal "http://www.example.com/login", headers["Location"]
  end
end
