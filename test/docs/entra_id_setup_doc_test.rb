require "test_helper"

# Keeps the operator-facing setup guide (docs/entra_id_setup.md) in step with
# the code: settings names, defaults, URIs and routes.
class EntraIdSetupDocTest < ActiveSupport::TestCase
  DOC_PATH = Rails.root.join("docs/entra_id_setup.md")
  STRUCTURE_PATH = Rails.root.join(".kiro/steering/structure.md")

  def doc
    @doc ||= DOC_PATH.read
  end

  def table_row(name)
    doc.lines.find { |line| line.lstrip.start_with?("|") && line.include?("`#{name}`") }
  end

  test "the guide exists" do
    assert DOC_PATH.file?, "docs/entra_id_setup.md is missing"
  end

  test "every environment variable Config reads is documented" do
    EntraAuth::Config::ENV_KEYS.each_value do |env_name|
      assert_includes doc, "`#{env_name}`", "#{env_name} is not documented"
    end
  end

  test "every credentials.entra_id key Config reads is documented next to its variable" do
    # Config reads credentials.entra_id[key] for exactly the keys of ENV_KEYS.
    EntraAuth::Config::ENV_KEYS.each do |key, env_name|
      row = table_row(env_name)
      assert row, "#{env_name} has no table row"
      assert_includes row, "`#{key}`", "credentials key #{key} is not on the row of #{env_name}"
    end
  end

  test "documented defaults equal the code defaults" do
    {
      idle_minutes: EntraAuth::Config::DEFAULT_IDLE_MINUTES,
      absolute_hours: EntraAuth::Config::DEFAULT_ABSOLUTE_HOURS
    }.each do |key, constant|
      row = table_row(EntraAuth::Config::ENV_KEYS.fetch(key))
      assert row, "row for #{key} is missing"
      assert_match(/既定値[^|]*\b#{constant}\b/, row, "default of #{key} (#{constant}) is not documented")
    end
  end

  test "defaults constants are what Config returns when nothing is set" do
    keys = EntraAuth::Config::ENV_KEYS.values_at(:idle_minutes, :absolute_hours)
    saved = keys.to_h { |k| [ k, ENV.delete(k) ] }
    Rails.application.credentials.stub(:entra_id, nil) do
      assert_equal EntraAuth::Config::DEFAULT_IDLE_MINUTES.minutes, EntraAuth::Config.idle_timeout
      assert_equal EntraAuth::Config::DEFAULT_ABSOLUTE_HOURS.hours, EntraAuth::Config.absolute_timeout
    end
  ensure
    saved.each { |k, v| ENV[k] = v if v }
  end

  test "the redirect URI path matches Config.redirect_uri" do
    path = URI(EntraAuth::Config.redirect_uri).path.delete_prefix(URI(EntraAuth::Config.app_base_url).path.chomp("/"))
    assert_includes doc, "<ENTRA_APP_BASE_URL>#{path}"
  end

  test "the post-logout path matches Config.post_logout_redirect_uri" do
    path = URI(EntraAuth::Config.post_logout_redirect_uri).path.delete_prefix(URI(EntraAuth::Config.app_base_url).path.chomp("/"))
    assert_equal "/signed_out", path
    assert_includes doc, "<ENTRA_APP_BASE_URL>#{path}"
  end

  test "documented routes exist" do
    {
      [ "/login", "GET" ] => "`/login`",
      [ "/logout", "DELETE" ] => "`DELETE /logout`",
      [ "/signed_out", "GET" ] => "`/signed_out`",
      [ "/users/auth/openid_connect", "POST" ] => "`POST /users/auth/openid_connect`",
      [ "/users/auth/openid_connect/callback", "GET" ] => "/users/auth/openid_connect/callback"
    }.each do |(path, verb), mention|
      assert_includes doc, mention
      begin
        Rails.application.routes.recognize_path(path, method: verb)
      rescue ActionController::RoutingError
        flunk "#{verb} #{path} is not routed"
      end
    end
  end

  test "structure steering documents the lib/entra_auth exception" do
    text = STRUCTURE_PATH.read
    assert_includes text, "lib/entra_auth"
    assert_includes text, "Zeitwerk"
    assert_includes text, "config/initializers/entra_auth.rb"
  end

  LOCALE_KEYS = %w[
    sessions.unavailable.title
    entra_authentication.failures.cancelled
    entra_authentication.failures.failed
    devise.failure.timeout
    devise.failure.absolute_timeout
  ].freeze

  test "the guide states the default locale" do
    assert_equal :en, I18n.default_locale
    assert_includes doc, "default_locale"
    assert_match(/既定のロケール[^\n]*`en`/, doc)
  end

  test "the locale table lists each key with the exact ja and en texts" do
    LOCALE_KEYS.each do |key|
      row = table_row(key)
      assert row, "#{key} has no row in the locale table"
      %i[ja en].each do |locale|
        text = I18n.t(key, locale: locale, raise: true)
        assert_includes row, text, "#{key} (#{locale}) text differs from the locale file"
      end
    end
  end

  test "every Config problems item name is documented" do
    %w[tenant_id client_id client_secret app_base_url idle_timeout absolute_timeout].each do |item|
      assert_includes doc, "`#{item}`", "problem item #{item} is not documented"
    end
    row = table_row("idle_timeout")
    assert row, "idle_timeout has no mapping row"
    assert_includes row, "ENTRA_SESSION_IDLE_MINUTES"
    assert_includes row, "idle_minutes"
    row = table_row("absolute_timeout")
    assert_includes row, "ENTRA_SESSION_ABSOLUTE_HOURS"
    assert_includes row, "absolute_hours"
  end

  test "the guide explains why lib/entra_auth is outside Zeitwerk" do
    assert_includes doc, "config.autoload_lib"
    assert_includes doc, "lib/entra_auth"
    assert_includes doc, "config/initializers/devise.rb"
    assert_includes doc, "config/initializers/entra_auth.rb"
    assert_includes Rails.root.join("config/application.rb").read, "ignore: %w[assets tasks entra_auth]"
  end

  test "the sign-out URL is nil only for incomplete configuration" do
    assert_nil EntraAuth::Config.stub(:tenant_id, "not-a-guid") { EntraAuth::LogoutUrl.build }
    assert_not_includes doc, "ネットワークの都合"
  end
end
