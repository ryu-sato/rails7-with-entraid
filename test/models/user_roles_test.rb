require "test_helper"

class UserRolesTest < ActiveSupport::TestCase
  def build_user(**attrs)
    User.new({ tid: "tenant-1", oid: SecureRandom.uuid }.merge(attrs))
  end

  test "roles defaults to an empty array" do
    assert_equal [], build_user.roles
    user = build_user.tap(&:save!)
    assert_equal [], user.reload.roles
  end

  test "a row inserted without roles (an existing user) gets an empty array" do
    User.connection.execute(
      "INSERT INTO users (tid, oid, created_at, updated_at) " \
      "VALUES ('t', 'legacy-oid', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
    )
    assert_equal [], User.find_by!(oid: "legacy-oid").roles
  end

  test "an array of role names is stored and read back" do
    user = build_user(roles: %w[admin member]).tap(&:save!)
    assert_equal %w[admin member], user.reload.roles
  end

  test "roles cannot be null" do
    user = build_user.tap(&:save!)
    assert_raises(ActiveRecord::NotNullViolation) { user.update_columns(roles: nil) }
  end
end
