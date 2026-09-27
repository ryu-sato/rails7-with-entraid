require "test_helper"

# Task 1.2: schema-level guarantees of the users table (Requirements 3.1, 3.4, 3.5).
# Uses raw SQL so it does not depend on the User model (task 3.3).
class UsersTableTest < ActiveSupport::TestCase
  self.use_transactional_tests = true
  self.fixture_table_names = [] if respond_to?(:fixture_table_names=)

  def conn = ActiveRecord::Base.connection

  def insert_user(tid:, oid:, name: nil, email: nil)
    now = Time.current.utc.strftime("%Y-%m-%d %H:%M:%S")
    conn.execute(
      "INSERT INTO users (tid, oid, name, email, created_at, updated_at) VALUES " \
      "(#{conn.quote(tid)}, #{conn.quote(oid)}, #{conn.quote(name)}, #{conn.quote(email)}, " \
      "#{conn.quote(now)}, #{conn.quote(now)})"
    )
  end

  test "users table has expected columns and no credential columns" do
    cols = conn.columns(:users).index_by(&:name)
    assert_equal %w[created_at email id name oid roles session_token tid updated_at], cols.keys.sort
    assert_equal false, cols["tid"].null
    assert_equal false, cols["oid"].null
    assert_equal true, cols["name"].null
    assert_equal true, cols["email"].null
    assert_equal :string, cols["tid"].type
    assert_equal :string, cols["oid"].type
    # Task 4.4: server-side session invalidation token (nullable string, no default).
    assert_equal :string, cols["session_token"].type
    assert_equal true, cols["session_token"].null
    assert_nil cols["session_token"].default
  end

  test "unique index on (tid, oid) exists" do
    idx = conn.indexes(:users).find { |i| i.columns == %w[tid oid] }
    assert idx, "expected index on [tid, oid]"
    assert idx.unique
  end

  test "duplicate (tid, oid) is rejected by the database" do
    insert_user(tid: "t1", oid: "o1")
    assert_raises(ActiveRecord::RecordNotUnique) { insert_user(tid: "t1", oid: "o1") }
  end

  test "same oid in a different tenant is allowed" do
    insert_user(tid: "t1", oid: "o1")
    assert_nothing_raised { insert_user(tid: "t2", oid: "o1") }
  end

  test "tid and oid are NOT NULL" do
    assert_raises(ActiveRecord::NotNullViolation) { insert_user(tid: nil, oid: "o1") }
    assert_raises(ActiveRecord::NotNullViolation) { insert_user(tid: "t1", oid: nil) }
  end

  test "name and email are nullable and email is not unique" do
    assert_nothing_raised do
      insert_user(tid: "t1", oid: "o1")
      insert_user(tid: "t1", oid: "o2", email: "a@example.com")
      insert_user(tid: "t1", oid: "o3", email: "a@example.com")
    end
  end
end
