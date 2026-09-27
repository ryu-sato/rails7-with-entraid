require "test_helper"

class Authorization::RoleSyncTest < ActiveSupport::TestCase
  Result = Authorization::Result

  GUID_ADMIN = "aaaaaaaa-0000-0000-0000-000000000001".freeze
  GUID_MEMBER = "bbbbbbbb-0000-0000-0000-000000000002".freeze
  GUID_OTHER = "cccccccc-0000-0000-0000-000000000003".freeze
  OVERAGE = { "_claim_names" => { "groups" => "src1" }, "_claim_sources" => { "src1" => { "endpoint" => "https://graph.invalid/u" } } }.freeze

  def settings(role_source, group_role_map = {})
    Config::Options.new.tap do |options|
      options.add_source!({ authorization: { role_source: role_source, group_role_map: group_role_map } })
      options.reload!
    end
  end

  def roles_settings = settings("roles")

  def groups_settings(map = { GUID_ADMIN => "admin", GUID_MEMBER => "member" })
    settings("groups", map)
  end

  def create_user(*roles)
    User.create!(tid: "tenant-1", oid: SecureRandom.uuid, roles: roles)
  end

  def sync(user, raw_info, config = roles_settings)
    Authorization::RoleSync.call(user: user, raw_info: raw_info, settings: config)
  end

  def capture_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  # --- roles claim method ---------------------------------------------------

  test "roles method: stores the defined roles and returns Synced" do
    user = create_user
    result = sync(user, "roles" => %w[member])
    assert_instance_of Result::Synced, result
    assert_equal %w[member], result.roles
    assert_equal %w[member], user.reload.roles
  end

  test "roles method: replaces previously stored roles (not a merge)" do
    user = create_user("admin")
    sync(user, "roles" => %w[member])
    assert_equal %w[member], user.reload.roles
  end

  test "roles method: a later sign-in reflects a changed assignment" do
    user = create_user
    sync(user, "roles" => %w[admin])
    assert_equal %w[admin], user.reload.roles
    sync(user, "roles" => %w[member])
    assert_equal %w[member], user.reload.roles
    sync(user, "roles" => %w[admin member])
    assert_equal %w[admin member], user.reload.roles
  end

  test "roles method: undefined roles are dropped, duplicates removed, definition order kept" do
    user = create_user
    result = sync(user, "roles" => %w[member ghost admin member])
    assert_equal %w[admin member], result.roles
    assert_equal %w[admin member], user.reload.roles
    assert_not_includes user.roles, "ghost"
  end

  test "roles method: only undefined roles is rejected as no_roles" do
    user = create_user("admin")
    result = sync(user, "roles" => %w[ghost])
    assert_instance_of Result::Rejected, result
    assert_equal :no_roles, result.reason
    assert_equal [], user.reload.roles
  end

  test "roles method: no roles claim is rejected as no_roles and old roles are cleared" do
    user = create_user("admin", "member")
    result = sync(user, {})
    assert_equal :no_roles, result.reason
    assert_equal [], user.reload.roles
  end

  test "roles method: all assignments revoked, then signing in again is rejected" do
    user = create_user
    assert_instance_of Result::Synced, sync(user, "roles" => %w[admin])
    result = sync(user, "roles" => [])
    assert_equal :no_roles, result.reason
    assert_equal [], user.reload.roles
  end

  test "roles method: a roles claim of the wrong type counts as no roles" do
    user = create_user("admin")
    assert_equal :no_roles, sync(user, "roles" => "admin").reason
    assert_equal [], user.reload.roles
  end

  test "roles method: groups claim is not used" do
    user = create_user
    result = sync(user, "groups" => [ GUID_ADMIN ])
    assert_equal :no_roles, result.reason
  end

  test "roles method: an overage-shaped token is never rejected for overage" do
    user = create_user
    result = sync(user, OVERAGE.merge("roles" => %w[admin]))
    assert_instance_of Result::Synced, result
    assert_equal %w[admin], user.reload.roles

    result = sync(user, OVERAGE)
    assert_equal :no_roles, result.reason
  end

  # --- groups claim method --------------------------------------------------

  test "groups method: maps listed groups to roles" do
    user = create_user
    result = sync(user, { "groups" => [ GUID_ADMIN, GUID_MEMBER, GUID_OTHER ] }, groups_settings)
    assert_instance_of Result::Synced, result
    assert_equal %w[admin member], user.reload.roles
  end

  test "groups method: replaces stored roles when membership changes" do
    user = create_user("admin")
    sync(user, { "groups" => [ GUID_MEMBER ] }, groups_settings)
    assert_equal %w[member], user.reload.roles
  end

  test "groups method: unmapped groups only is rejected as no_roles" do
    user = create_user("admin")
    result = sync(user, { "groups" => [ GUID_OTHER ] }, groups_settings)
    assert_equal :no_roles, result.reason
    assert_equal [], user.reload.roles
  end

  test "groups method: a mapping to an undefined role grants nothing" do
    user = create_user
    result = sync(user, { "groups" => [ GUID_ADMIN ] }, groups_settings(GUID_ADMIN => "ghost"))
    assert_equal :no_roles, result.reason
    assert_equal [], user.reload.roles
  end

  test "groups method: several groups to the same role give the role once" do
    user = create_user
    sync(user, { "groups" => [ GUID_ADMIN, GUID_OTHER ] }, groups_settings(GUID_ADMIN => "admin", GUID_OTHER => "admin"))
    assert_equal %w[admin], user.reload.roles
  end

  test "groups method: overage is rejected as groups_overage and old roles are cleared" do
    user = create_user("admin")
    result = sync(user, OVERAGE, groups_settings)
    assert_instance_of Result::Rejected, result
    assert_equal :groups_overage, result.reason
    assert_equal [], user.reload.roles
  end

  test "groups method: no groups and no overage is rejected as no_roles" do
    result = sync(create_user, {}, groups_settings)
    assert_equal :no_roles, result.reason
  end

  test "groups method: roles claim is not used" do
    result = sync(create_user, { "roles" => %w[admin] }, groups_settings)
    assert_equal :no_roles, result.reason
  end

  test "groups method: an empty map rejects everyone as no_roles" do
    result = sync(create_user, { "groups" => [ GUID_ADMIN ] }, groups_settings({}))
    assert_equal :no_roles, result.reason
  end

  # --- same rules for both methods -----------------------------------------

  test "both methods apply the same common rules to equivalent input" do
    [
      [ roles_settings, { "roles" => %w[ghost] } ],
      [ groups_settings(GUID_ADMIN => "ghost"), { "groups" => [ GUID_ADMIN ] } ]
    ].each do |config, raw|
      assert_equal :no_roles, sync(create_user("admin"), raw, config).reason
    end

    [
      [ roles_settings, { "roles" => %w[member ghost admin admin] } ],
      [ groups_settings(GUID_ADMIN => "admin", GUID_MEMBER => "member", GUID_OTHER => "ghost"),
        { "groups" => [ GUID_MEMBER, GUID_OTHER, GUID_ADMIN, GUID_ADMIN ] } ]
    ].each do |config, raw|
      user = create_user
      assert_equal %w[admin member], sync(user, raw, config).roles
      assert_equal %w[admin member], user.reload.roles
    end
  end

  test "the method is taken from the settings on every call" do
    user = create_user
    raw = { "roles" => %w[admin], "groups" => [ GUID_MEMBER ] }
    assert_equal %w[admin], sync(user, raw, roles_settings).roles
    assert_equal %w[member], sync(user, raw, groups_settings).roles
  end

  test "an unset or unsupported role_source raises instead of guessing" do
    [ "", nil, "saml" ].each do |value|
      assert_raises(Authorization::RoleSource::ConfigurationError) { sync(create_user, { "roles" => %w[admin] }, settings(value)) }
    end
  end

  test "the default settings of the test environment are used when none are given" do
    user = create_user
    result = Authorization::RoleSync.call(user: user, raw_info: { "roles" => %w[admin] })
    assert_instance_of Result::Synced, result
  end

  # --- persistence and logging ---------------------------------------------

  test "success stores the roles and does not touch other attributes" do
    user = create_user
    user.update!(name: "Alice", email: "alice@example.com")
    sync(user, "roles" => %w[admin])
    user.reload
    assert_equal [ "Alice", "alice@example.com" ], [ user.name, user.email ]
  end

  test "an unsaved user is rejected without raising and nothing is written" do
    user = User.new(tid: "t", oid: "o")
    result = nil
    assert_no_difference "User.count" do
      result = sync(user, {})
    end
    assert_equal :no_roles, result.reason
  end

  test "a rejection is logged with the reason and user id only" do
    user = create_user("admin")
    log = capture_log { sync(user, { "groups" => [ "SENTINEL-GUID" ], "roles" => [ "SENTINEL-ROLE" ] }, groups_settings) }
    line = log[/\[authorization\] login rejected[^\n]*/]
    assert_not_nil line, "expected a rejection log line"
    assert_includes line, "reason=no_roles"
    assert_includes line, "user_id=#{user.id}"
    assert_no_match(/SENTINEL/, log)
  end

  test "an overage rejection is logged with its own reason" do
    user = create_user
    log = capture_log { sync(user, OVERAGE, groups_settings) }
    assert_match(/login rejected reason=groups_overage user_id=#{user.id}/, log)
    assert_no_match(/graph\.invalid|src1/, log)
  end

  test "a successful sync logs no claim contents" do
    user = create_user
    log = capture_log { sync(user, "roles" => %w[admin SENTINEL-ROLE], "groups" => %w[SENTINEL-GUID]) }
    assert_no_match(/SENTINEL/, log)
    assert_no_match(/login rejected/, log)
  end

  test "syncing the same input twice gives the same result" do
    user = create_user
    first = sync(user, "roles" => %w[member admin])
    second = sync(user, "roles" => %w[member admin])
    assert_equal first, second
  end

  test "the session and sign-in state are not RoleSync's business (no session argument)" do
    params = Authorization::RoleSync.method(:call).parameters
    assert_equal %i[user raw_info settings], params.map(&:last)
  end
end
