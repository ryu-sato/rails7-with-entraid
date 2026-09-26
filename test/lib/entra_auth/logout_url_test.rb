require "test_helper"
require "minitest/mock"

class EntraAuthLogoutUrlTest < ActiveSupport::TestCase
  GUID = "11111111-2222-3333-4444-555555555555".freeze
  BASE = "https://app.example.com".freeze
  ENV_NAMES = %w[
    ENTRA_TENANT_ID ENTRA_CLIENT_ID ENTRA_CLIENT_SECRET ENTRA_APP_BASE_URL
    ENTRA_SESSION_IDLE_MINUTES ENTRA_SESSION_ABSOLUTE_HOURS
  ].freeze

  # Runs the block with exactly the given ENTRA_* env (all others unset) and
  # no credentials.entra_id; restores both afterwards.
  def with_settings(env)
    saved = ENV_NAMES.to_h { |name| [ name, ENV[name] ] }
    ENV_NAMES.each { |name| ENV.delete(name) }
    env.each { |name, value| ENV[name] = value }
    Rails.application.credentials.stub(:entra_id, nil) { yield }
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  def full_env(overrides = {})
    { "ENTRA_TENANT_ID" => GUID, "ENTRA_CLIENT_ID" => "client-id",
      "ENTRA_CLIENT_SECRET" => "s3cr3t-value", "ENTRA_APP_BASE_URL" => BASE }.merge(overrides)
  end

  def query_of(url) = URI.decode_www_form(URI.parse(url).query.to_s)

  test "builds the exact URL with post_logout_redirect_uri and logout_hint" do
    with_settings(full_env) do
      expected = "https://login.microsoftonline.com/#{GUID}/oauth2/v2.0/logout" \
                 "?post_logout_redirect_uri=https%3A%2F%2Fapp.example.com%2Fsigned_out" \
                 "&logout_hint=user%40example.com"
      assert_equal expected, EntraAuth::LogoutUrl.build(logout_hint: "user@example.com")
    end
  end

  test "builds the exact URL without logout_hint when it is nil" do
    with_settings(full_env) do
      expected = "https://login.microsoftonline.com/#{GUID}/oauth2/v2.0/logout" \
                 "?post_logout_redirect_uri=https%3A%2F%2Fapp.example.com%2Fsigned_out"
      assert_equal expected, EntraAuth::LogoutUrl.build(logout_hint: nil)
      assert_equal expected, EntraAuth::LogoutUrl.build
    end
  end

  test "omits logout_hint when it is blank or whitespace" do
    with_settings(full_env) do
      [ "", " ", "  \t\n" ].each do |blank|
        url = EntraAuth::LogoutUrl.build(logout_hint: blank)
        assert_equal [ "post_logout_redirect_uri" ], query_of(url).map(&:first), "hint=#{blank.inspect}"
        assert_not_includes url, "logout_hint"
      end
    end
  end

  test "host and path match exactly and the tenant comes from Config" do
    with_settings(full_env("ENTRA_TENANT_ID" => "99999999-8888-7777-6666-555555555555")) do
      uri = URI.parse(EntraAuth::LogoutUrl.build(logout_hint: "a"))
      assert_equal "https", uri.scheme
      assert_equal "login.microsoftonline.com", uri.host
      assert_equal "/99999999-8888-7777-6666-555555555555/oauth2/v2.0/logout", uri.path
    end
  end

  test "post_logout_redirect_uri equals Config's value" do
    with_settings(full_env("ENTRA_APP_BASE_URL" => "http://localhost:3000/")) do
      params = query_of(EntraAuth::LogoutUrl.build(logout_hint: "a")).to_h
      assert_equal EntraAuth::Config.post_logout_redirect_uri, params["post_logout_redirect_uri"]
      assert_equal "http://localhost:3000/signed_out", params["post_logout_redirect_uri"]
    end
  end

  test "logout_hint round-trips through percent-encoding for tricky characters" do
    with_settings(full_env) do
      [ "a+b@example.com", "a&b=c@example.com", "user name@例.jp", "100%", "x#y?z", "日本語@example.com" ].each do |hint|
        url = EntraAuth::LogoutUrl.build(logout_hint: hint)
        assert_equal hint, query_of(url).to_h["logout_hint"], "hint=#{hint.inspect}"
        assert_equal 2, query_of(url).size
      end
    end
  end

  test "never includes id_token_hint, client_id or secrets" do
    with_settings(full_env) do
      url = EntraAuth::LogoutUrl.build(logout_hint: "user@example.com")
      assert_equal %w[post_logout_redirect_uri logout_hint], query_of(url).map(&:first)
      %w[id_token_hint client_id client_secret s3cr3t-value].each { |word| assert_not_includes url, word }
    end
  end

  test "returns nil when the tenant is missing or not a GUID" do
    [ nil, "not-a-guid" ].each do |tenant|
      env = full_env
      tenant.nil? ? env.delete("ENTRA_TENANT_ID") : env["ENTRA_TENANT_ID"] = tenant
      with_settings(env) { assert_nil EntraAuth::LogoutUrl.build(logout_hint: "a@example.com") }
    end
  end

  test "returns nil when app_base_url is missing or invalid" do
    with_settings(full_env.except("ENTRA_APP_BASE_URL")) do
      assert_nil EntraAuth::LogoutUrl.build(logout_hint: "a@example.com")
    end
    with_settings(full_env("ENTRA_APP_BASE_URL" => "not a url")) do
      assert_nil EntraAuth::LogoutUrl.build(logout_hint: "a@example.com")
    end
  end

  test "does not raise when nothing is configured" do
    with_settings({}) { assert_nil EntraAuth::LogoutUrl.build(logout_hint: nil) }
  end

  test "makes no network request" do
    with_settings(full_env) do
      EntraAuth::LogoutUrl.build(logout_hint: "a@example.com")
      EntraAuth::LogoutUrl.build
    end
    assert_not_requested :any, /.*/
  end
end
