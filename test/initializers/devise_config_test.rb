require "test_helper"
require "minitest/mock"
require "open3"

# Task 3.1: config/initializers/devise.rb (Devise + OmniAuth provider).
class DeviseConfigTest < ActiveSupport::TestCase
  GUID = "11111111-2222-3333-4444-555555555555".freeze
  ENV_NAMES = %w[
    ENTRA_TENANT_ID ENTRA_CLIENT_ID ENTRA_CLIENT_SECRET ENTRA_APP_BASE_URL
    ENTRA_SESSION_IDLE_MINUTES ENTRA_SESSION_ABSOLUTE_HOURS
  ].freeze

  def with_settings(env: {})
    saved = ENV_NAMES.to_h { |name| [ name, ENV[name] ] }
    ENV_NAMES.each { |name| ENV.delete(name) }
    env.each { |name, value| ENV[name] = value }
    Rails.application.credentials.stub(:entra_id, nil) { yield }
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  def full_env
    {
      "ENTRA_TENANT_ID" => GUID,
      "ENTRA_CLIENT_ID" => "client-id",
      "ENTRA_CLIENT_SECRET" => "s3cr3t-value",
      "ENTRA_APP_BASE_URL" => "https://app.example.com"
    }
  end

  # A fake Rack env carrying a real strategy instance, as OmniAuth does.
  def strategy_env
    strategy = EntraAuth::Strategy.new(nil)
    [ { "omniauth.strategy" => strategy }, strategy ]
  end

  def provider_config
    Devise.omniauth_configs[:openid_connect]
  end

  def run_setup(env)
    setup = provider_config.options[:setup]
    setup.call(env)
  end

  # Boots the app in a fresh process with exactly the given ENTRA_* env and
  # returns [stdout, stderr, status]. No network is involved at boot.
  def boot_subprocess(script, entra_env: {}, rails_env: "test")
    clean = ENV_NAMES.to_h { |name| [ name, nil ] }
    env = clean.merge(entra_env).merge("RAILS_ENV" => rails_env, "DATABASE_URL" => nil)
    Open3.capture3(env, Rails.root.join("bin/rails").to_s, "runner", script, chdir: Rails.root.to_s)
  end

  test "Devise timeout_in is the configured idle timeout" do
    assert_equal EntraAuth::Config.idle_timeout, Devise.timeout_in
  end

  test "Devise timeout_in follows ENTRA_SESSION_IDLE_MINUTES at boot" do
    out, err, status = boot_subprocess("puts Devise.timeout_in.to_i",
                                       entra_env: { "ENTRA_SESSION_IDLE_MINUTES" => "45" })
    assert_predicate status, :success?, err
    assert_equal 45 * 60, out.lines.last.to_i
  end

  test "Devise timeout_in defaults to 30 minutes at boot" do
    out, err, status = boot_subprocess("puts Devise.timeout_in.to_i")
    assert_predicate status, :success?, err
    assert_equal 30 * 60, out.lines.last.to_i
  end

  test "authentication keys are not normalized" do
    assert_equal [], Devise.case_insensitive_keys
    assert_equal [], Devise.strip_whitespace_keys
  end

  test "sign out resets all scopes and uses DELETE" do
    assert_equal true, Devise.sign_out_all_scopes
    assert_equal :delete, Devise.sign_out_via
  end

  test "navigational formats include turbo_stream and responder statuses are Turbo friendly" do
    assert_includes Devise.navigational_formats, :turbo_stream
    assert_includes Devise.navigational_formats, "*/*"
    assert_equal :unprocessable_entity, Devise.responder.error_status
    assert_equal :see_other, Devise.responder.redirect_status
    assert_equal "ApplicationController", Devise.parent_controller
  end

  test "no password or remember-me settings are configured" do
    assert_equal 14.days, Devise.remember_for
    assert_equal 12, Devise.stretches
    assert_nil Devise.mailer_sender
    assert_nil Devise.pepper
  end

  test "openid_connect provider is registered with the EntraAuth strategy" do
    assert_equal [ :openid_connect ], Devise.omniauth_providers
    assert_equal EntraAuth::Strategy, provider_config.strategy_class
    assert_respond_to provider_config.options[:setup], :call
  end

  test "setup resolves issuer and client options from Config at request time" do
    with_settings(env: full_env) do
      env, strategy = strategy_env
      run_setup(env)
      assert_equal "https://login.microsoftonline.com/#{GUID}/v2.0", strategy.options.issuer
      assert_equal "client-id", strategy.options.client_options.identifier
      assert_equal "s3cr3t-value", strategy.options.client_options.secret
      assert_equal "https://app.example.com/users/auth/openid_connect/callback",
                   strategy.options.client_options.redirect_uri
    end
  end

  test "setup reads Config on every call (no memoization)" do
    with_settings(env: full_env) { run_setup(strategy_env.first) }
    with_settings(env: full_env.merge("ENTRA_CLIENT_ID" => "other-id")) do
      env, strategy = strategy_env
      run_setup(env)
      assert_equal "other-id", strategy.options.client_options.identifier
    end
  end

  test "setup does not raise and leaves values nil when Config is unset" do
    with_settings do
      env, strategy = strategy_env
      assert_nothing_raised { run_setup(env) }
      assert_nil strategy.options.issuer
      assert_nil strategy.options.client_options.identifier
      assert_nil strategy.options.client_options.secret
      assert_nil strategy.options.client_options.redirect_uri
    end
  end

  test "setup ignores a missing strategy in env" do
    assert_nothing_raised { run_setup({}) }
  end

  test "OmniAuth invokes setup with the request env during setup_phase" do
    with_settings(env: full_env) do
      env, strategy = strategy_env
      strategy.instance_variable_set(:@env, env)
      strategy.options[:setup] = provider_config.options[:setup]
      strategy.send(:setup_phase)
      assert_equal "client-id", strategy.options.client_options.identifier
    end
  end

  test "the app boots with no ENTRA_* set (test and production)" do
    out, err, status = boot_subprocess("puts :booted")
    assert_predicate status, :success?, err
    assert_includes out, "booted"

    out, err, status = boot_subprocess("puts :booted", rails_env: "production")
    assert_predicate status, :success?, err
    assert_includes out, "booted"
  end
end
