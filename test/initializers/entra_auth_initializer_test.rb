require "test_helper"
require "open3"

# Task 3.2: config/initializers/entra_auth.rb and filter_parameter_logging.rb.
class EntraAuthInitializerTest < ActiveSupport::TestCase
  GUID = "11111111-2222-3333-4444-555555555555".freeze
  ENTRA_ENV_NAMES = %w[
    ENTRA_TENANT_ID ENTRA_CLIENT_ID ENTRA_CLIENT_SECRET ENTRA_APP_BASE_URL
    ENTRA_SESSION_IDLE_MINUTES ENTRA_SESSION_ABSOLUTE_HOURS
  ].freeze
  # Not a real key: only lets a production process boot without credentials.
  FAKE_SECRET_KEY_BASE = ("ab" * 64).freeze
  INITIALIZER = Rails.root.join("config/initializers/entra_auth.rb").to_s.freeze

  # Boots a separate process with a cleaned environment (no real ENTRA_*, no
  # DATABASE_URL, no network access is made: boot only).
  def boot(rails_env, extra_env = {}, script: "puts :booted")
    env = ENTRA_ENV_NAMES.to_h { |name| [ name, nil ] }
    env.merge!("DATABASE_URL" => nil, "SECRET_KEY_BASE_DUMMY" => nil, "SECRET_KEY_BASE" => nil,
               "RAILS_ENV" => rails_env)
    env["SECRET_KEY_BASE"] = FAKE_SECRET_KEY_BASE if rails_env == "production"
    env.merge!(extra_env)
    output, status = Open3.capture2e(env, "bin/rails", "runner", script, chdir: Rails.root.to_s)
    [ output, status ]
  end

  def valid_entra_env
    {
      "ENTRA_TENANT_ID" => GUID,
      "ENTRA_CLIENT_ID" => "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
      "ENTRA_CLIENT_SECRET" => "s3cr3t-value-XYZ",
      "ENTRA_APP_BASE_URL" => "https://app.example.com"
    }
  end

  def filter
    ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  end

  # --- AbsoluteTimeout wiring (6.2 wiring) ---

  test "the absolute timeout hook is installed in every environment" do
    %w[development test production].each do |rails_env|
      output, status = boot(rails_env, { "SECRET_KEY_BASE_DUMMY" => "1" },
                            script: "puts \"installed=\#{EntraAuth::AbsoluteTimeout.installed?}\"")
      assert status.success?, "#{rails_env}: #{output}"
      assert_includes output, "installed=true", rails_env
    end
  end

  test "the hook is registered exactly once even if the initializer is loaded again" do
    2.times { load INITIALIZER }
    count = Warden::Manager._after_set_user.count { |callback, _| callback.equal?(EntraAuth::AbsoluteTimeout::HOOK) }
    assert_equal 1, count
    assert EntraAuth::AbsoluteTimeout.installed?
  end

  # --- Boot-time validation (8.3) ---

  test "production boot with no ENTRA settings fails naming the items only" do
    output, status = boot("production")
    assert_not status.success?
    %w[tenant_id client_id client_secret app_base_url].each { |name| assert_includes output, name }
    assert_includes output, "EntraAuth::ConfigurationError"
  end

  test "production boot with a bad client secret and tenant reports names but never the values" do
    output, status = boot("production", {
      "ENTRA_TENANT_ID" => "common", "ENTRA_CLIENT_SECRET" => "s3cr3t-value-XYZ"
    })
    assert_not status.success?
    assert_includes output, "tenant_id"
    assert_includes output, "client_id"
    assert_includes output, "app_base_url"
    assert_not_includes output, "s3cr3t-value-XYZ"
    assert_not_includes output, "common"
    assert_not_includes output, FAKE_SECRET_KEY_BASE
  end

  test "production boot with SECRET_KEY_BASE_DUMMY skips validation (asset precompile)" do
    output, status = boot("production", { "SECRET_KEY_BASE_DUMMY" => "1", "SECRET_KEY_BASE" => nil })
    assert status.success?, output
    assert_includes output, "booted"
  end

  test "production boot with a valid configuration succeeds" do
    output, status = boot("production", valid_entra_env)
    assert status.success?, output
    assert_includes output, "booted"
    assert_not_includes output, "s3cr3t-value-XYZ"
  end

  test "development and test boots never validate" do
    %w[development test].each do |rails_env|
      output, status = boot(rails_env)
      assert status.success?, "#{rails_env}: #{output}"
      assert_includes output, "booted"
    end
  end

  # --- Parameter filtering (8.2) ---

  test "authorization code, state, nonce and tokens are masked" do
    params = {
      "code" => "auth-code", "state" => "st", "nonce" => "no", "id_token" => "jwt",
      "access_token" => "at", "client_secret" => "cs", "login_hint" => "hint"
    }
    filtered = filter.filter(params)
    params.each_key { |key| assert_equal "[FILTERED]", filtered[key], key }
  end

  test "nested and symbol keys are masked too" do
    filtered = filter.filter(user: { code: "x" }, "state" => "y")
    assert_equal "[FILTERED]", filtered[:user][:code]
    assert_equal "[FILTERED]", filtered["state"]
  end

  test "unrelated parameters containing code or state are not masked" do
    filtered = filter.filter("zipcode" => "100", "estate" => "yes", "statement" => "s", "name" => "n")
    assert_equal "100", filtered["zipcode"]
    assert_equal "yes", filtered["estate"]
    assert_equal "s", filtered["statement"]
    assert_equal "n", filtered["name"]
  end

  test "existing filters are kept" do
    filtered = filter.filter("password" => "p", "email" => "e", "secret" => "s", "api_key" => "k")
    filtered.each_value { |value| assert_equal "[FILTERED]", value }
  end
end
