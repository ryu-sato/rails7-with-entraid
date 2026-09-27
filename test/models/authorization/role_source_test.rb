require "test_helper"

class Authorization::RoleSourceTest < ActiveSupport::TestCase
  def settings_with(authorization)
    Config::Options.new.tap do |settings|
      settings.add_source!({ authorization: authorization })
      settings.reload!
    end
  end

  def capture_warnings
    io = StringIO.new
    logger = Logger.new(io)
    yield logger
    io.string
  end

  test "the current environment settings are valid" do
    assert_includes Authorization::RoleSource::SOURCES, Authorization::RoleSource.current
    assert_nothing_raised { Authorization::RoleSource.validate!(logger: Logger.new(nil)) }
  end

  test "current returns the configured source" do
    assert_equal "roles", Authorization::RoleSource.current(settings_with(role_source: "roles"))
    assert_equal "groups", Authorization::RoleSource.current(settings_with(role_source: "groups"))
  end

  test "an unset role_source raises an error naming the setting" do
    [ {}, { role_source: nil }, { role_source: "" } ].each do |authorization|
      error = assert_raises(Authorization::RoleSource::ConfigurationError) do
        Authorization::RoleSource.current(settings_with(authorization))
      end
      assert_match "authorization.role_source", error.message
      assert_match "roles", error.message
      assert_match "groups", error.message
    end
  end

  test "a settings object without an authorization section raises too" do
    error = assert_raises(Authorization::RoleSource::ConfigurationError) do
      Authorization::RoleSource.current(Config::Options.new)
    end
    assert_match "authorization.role_source", error.message
  end

  test "an unsupported role_source raises an error that does not echo the value" do
    error = assert_raises(Authorization::RoleSource::ConfigurationError) do
      Authorization::RoleSource.current(settings_with(role_source: "saml-secret-ish"))
    end
    assert_match "authorization.role_source", error.message
    assert_no_match(/saml-secret-ish/, error.message)
  end

  test "validate! raises for an unsupported source" do
    assert_raises(Authorization::RoleSource::ConfigurationError) do
      Authorization::RoleSource.validate!(settings_with(role_source: "oauth"), logger: Logger.new(nil))
    end
  end

  test "group_role_map normalizes GUID keys to lowercase strings" do
    settings = settings_with(role_source: "groups", group_role_map: { "AAAAAAAA-0000-0000-0000-000000000001": "admin" })
    assert_equal({ "aaaaaaaa-0000-0000-0000-000000000001" => "admin" }, Authorization::RoleSource.group_role_map(settings))
  end

  test "group_role_map is empty when unset" do
    assert_equal({}, Authorization::RoleSource.group_role_map(settings_with(role_source: "roles")))
  end

  test "group_role_map values are strings" do
    settings = settings_with(role_source: "groups", group_role_map: { "g-1": :admin })
    assert_equal({ "g-1" => "admin" }, Authorization::RoleSource.group_role_map(settings))
  end

  test "groups source warns about a mapping to an undefined role without printing GUIDs" do
    settings = settings_with(role_source: "groups", group_role_map: { "11111111-2222-3333-4444-555555555555": "ghost", "g-2": "admin" })
    output = capture_warnings { |logger| Authorization::RoleSource.validate!(settings, logger: logger) }
    assert_match "ghost", output
    assert_no_match(/11111111-2222/, output)
    assert_no_match(/g-2/, output)
  end

  test "groups source warns when the mapping is empty" do
    output = capture_warnings do |logger|
      Authorization::RoleSource.validate!(settings_with(role_source: "groups", group_role_map: {}), logger: logger)
    end
    assert_match "group_role_map", output
  end

  test "roles source does not warn about the group mapping" do
    output = capture_warnings do |logger|
      Authorization::RoleSource.validate!(settings_with(role_source: "roles", group_role_map: { "g-1": "ghost" }), logger: logger)
    end
    assert_equal "", output
  end

  test "a valid groups configuration does not warn" do
    output = capture_warnings do |logger|
      Authorization::RoleSource.validate!(settings_with(role_source: "groups", group_role_map: { "g-1": "admin" }), logger: logger)
    end
    assert_equal "", output
  end
end
