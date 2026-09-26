require "test_helper"
require "minitest/mock"

class EntraAuthConfigTest < ActiveSupport::TestCase
  GUID = "11111111-2222-3333-4444-555555555555".freeze
  CRED_GUID = "99999999-8888-7777-6666-555555555555".freeze
  SECRET = "s3cr3t-value-XYZ".freeze
  ENV_NAMES = %w[
    ENTRA_TENANT_ID ENTRA_CLIENT_ID ENTRA_CLIENT_SECRET ENTRA_APP_BASE_URL
    ENTRA_SESSION_IDLE_MINUTES ENTRA_SESSION_ABSOLUTE_HOURS
  ].freeze




  # Runs the block with exactly the given ENTRA_* env (all others unset) and
  # the given credentials.entra_id hash; restores both afterwards.
  def with_settings(env: {}, credentials: nil)
    saved = ENV_NAMES.to_h { |name| [ name, ENV[name] ] }
    ENV_NAMES.each { |name| ENV.delete(name) }
    env.each { |name, value| ENV[name] = value }
    Rails.application.credentials.stub(:entra_id, credentials) { yield }
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  def full_env(overrides = {})
    {
      "ENTRA_TENANT_ID" => GUID,
      "ENTRA_CLIENT_ID" => "client-id",
      "ENTRA_CLIENT_SECRET" => SECRET,
      "ENTRA_APP_BASE_URL" => "https://app.example.com"
    }.merge(overrides)
  end

  test "reads values from ENV" do
    with_settings(env: full_env) do
      assert_equal GUID, EntraAuth::Config.tenant_id
      assert_equal "client-id", EntraAuth::Config.client_id
      assert_equal SECRET, EntraAuth::Config.client_secret
      assert_equal "https://app.example.com", EntraAuth::Config.app_base_url
      assert_predicate EntraAuth::Config, :valid?
      assert_empty EntraAuth::Config.problems
    end
  end

  test "falls back to credentials.entra_id when ENV is unset" do
    creds = { tenant_id: CRED_GUID, client_id: "c-id", client_secret: SECRET,
              app_base_url: "https://cred.example.com" }
    with_settings(credentials: creds) do
      assert_equal CRED_GUID, EntraAuth::Config.tenant_id
      assert_equal "c-id", EntraAuth::Config.client_id
      assert_equal SECRET, EntraAuth::Config.client_secret
      assert_equal "https://cred.example.com", EntraAuth::Config.app_base_url
      assert_predicate EntraAuth::Config, :valid?
    end
  end

  test "ENV takes precedence over credentials, per key" do
    creds = { tenant_id: CRED_GUID, client_id: "cred-client", client_secret: "cred-secret",
              app_base_url: "https://cred.example.com" }
    with_settings(env: { "ENTRA_TENANT_ID" => GUID }, credentials: creds) do
      assert_equal GUID, EntraAuth::Config.tenant_id
      assert_equal "cred-client", EntraAuth::Config.client_id
    end
  end

  test "blank ENV falls back to credentials" do
    with_settings(env: { "ENTRA_CLIENT_ID" => "  " }, credentials: { client_id: "cred-client" }) do
      assert_equal "cred-client", EntraAuth::Config.client_id
    end
  end

  test "everything unset reports all required items without raising" do
    with_settings do
      assert_nil EntraAuth::Config.tenant_id
      assert_equal %i[tenant_id client_id client_secret app_base_url], EntraAuth::Config.problems
      assert_not EntraAuth::Config.valid?
      assert_nil EntraAuth::Config.issuer
      assert_nil EntraAuth::Config.redirect_uri
      assert_nil EntraAuth::Config.post_logout_redirect_uri
    end
  end

  test "tenant_id accepts only a GUID" do
    [ "common", "organizations", "consumers", "COMMON", "contoso.onmicrosoft.com",
     "1111111-2222-3333-4444-555555555555", "#{GUID}x", "{#{GUID}}" ].each do |bad|
      with_settings(env: full_env("ENTRA_TENANT_ID" => bad)) do
        assert_equal [ :tenant_id ], EntraAuth::Config.problems, "expected #{bad.inspect} to be rejected"
        assert_nil EntraAuth::Config.issuer
        assert_not EntraAuth::Config.valid?
      end
    end
    with_settings(env: full_env("ENTRA_TENANT_ID" => GUID.upcase)) do
      assert_empty EntraAuth::Config.problems
    end
  end

  test "timeouts default to 30 minutes idle and 8 hours absolute" do
    with_settings(env: full_env) do
      assert_equal 30.minutes, EntraAuth::Config.idle_timeout
      assert_equal 8.hours, EntraAuth::Config.absolute_timeout
      assert_empty EntraAuth::Config.problems
    end
  end

  test "timeouts are read from ENV then credentials" do
    with_settings(env: full_env("ENTRA_SESSION_IDLE_MINUTES" => "15"),
                  credentials: { idle_minutes: 45, absolute_hours: 4 }) do
      assert_equal 15.minutes, EntraAuth::Config.idle_timeout
      assert_equal 4.hours, EntraAuth::Config.absolute_timeout
      assert_empty EntraAuth::Config.problems
    end
    with_settings(env: full_env("ENTRA_SESSION_ABSOLUTE_HOURS" => "12")) do
      assert_equal 12.hours, EntraAuth::Config.absolute_timeout
    end
  end

  test "invalid timeouts are reported, not silently defaulted" do
    %w[0 -5 abc 1.5 10m].each do |bad|
      with_settings(env: full_env("ENTRA_SESSION_IDLE_MINUTES" => bad,
                                  "ENTRA_SESSION_ABSOLUTE_HOURS" => bad)) do
        assert_equal %i[idle_timeout absolute_timeout], EntraAuth::Config.problems,
                     "expected #{bad.inspect} to be reported"
        assert_not EntraAuth::Config.valid?
        assert_nothing_raised { EntraAuth::Config.idle_timeout; EntraAuth::Config.absolute_timeout }
      end
    end
    with_settings(env: full_env, credentials: { idle_minutes: 0, absolute_hours: -1 }) do
      assert_equal %i[idle_timeout absolute_timeout], EntraAuth::Config.problems
    end
  end

  test "app_base_url must be an http(s) URL; trailing slash is ignored" do
    with_settings(env: full_env("ENTRA_APP_BASE_URL" => "not a url")) do
      assert_equal [ :app_base_url ], EntraAuth::Config.problems
      assert_nil EntraAuth::Config.redirect_uri
    end
    with_settings(env: full_env("ENTRA_APP_BASE_URL" => "ftp://example.com")) do
      assert_equal [ :app_base_url ], EntraAuth::Config.problems
    end
    with_settings(env: full_env("ENTRA_APP_BASE_URL" => "https://app.example.com/")) do
      assert_empty EntraAuth::Config.problems
      assert_equal "https://app.example.com/users/auth/openid_connect/callback", EntraAuth::Config.redirect_uri
    end
  end

  test "derives issuer, redirect_uri and post_logout_redirect_uri" do
    with_settings(env: full_env) do
      assert_equal "https://login.microsoftonline.com/#{GUID}/v2.0", EntraAuth::Config.issuer
      assert_equal "https://app.example.com/users/auth/openid_connect/callback", EntraAuth::Config.redirect_uri
      assert_equal "https://app.example.com/signed_out", EntraAuth::Config.post_logout_redirect_uri
    end
  end

  test "problems contains item names only, never values" do
    with_settings(env: full_env("ENTRA_TENANT_ID" => "common-secret-tenant",
                                "ENTRA_SESSION_IDLE_MINUTES" => "bad-value-123")) do
      problems = EntraAuth::Config.problems
      assert_kind_of Array, problems
      assert(problems.all?(Symbol))
      assert_equal %i[tenant_id idle_timeout], problems
      text = problems.inspect
      assert_not_includes text, "common-secret-tenant"
      assert_not_includes text, "bad-value-123"
      assert_not_includes text, SECRET
    end
  end

  test "validate! passes when valid" do
    with_settings(env: full_env) { assert_nil EntraAuth::Config.validate! }
  end

  test "validate! raises ConfigurationError with item names only" do
    with_settings(env: full_env("ENTRA_TENANT_ID" => "common", "ENTRA_CLIENT_SECRET" => "")) do
      error = assert_raises(EntraAuth::ConfigurationError) { EntraAuth::Config.validate! }
      assert_kind_of StandardError, error
      assert_includes error.message, "tenant_id"
      assert_includes error.message, "client_secret"
      assert_not_includes error.message, "common"
      assert_not_includes error.message, SECRET
    end
  end

  test "client secret never appears in inspect, to_s or error messages" do
    with_settings(env: full_env("ENTRA_TENANT_ID" => "common")) do
      assert_not_includes EntraAuth::Config.inspect, SECRET
      assert_not_includes EntraAuth::Config.to_s, SECRET
      error = assert_raises(EntraAuth::ConfigurationError) { EntraAuth::Config.validate! }
      assert_not_includes error.message, SECRET
      assert_not_includes error.inspect, SECRET
    end
  end
end
