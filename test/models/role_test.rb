require "test_helper"

class RoleTest < ActiveSupport::TestCase
  test "NAMES is a frozen list of role names" do
    assert_kind_of Array, Role::NAMES
    assert Role::NAMES.frozen?
    assert Role::NAMES.all? { |name| name.is_a?(String) && name.present? }
    assert_equal Role::NAMES.uniq, Role::NAMES
  end

  test "known keeps only defined roles" do
    assert_equal [ "admin" ], Role.known(%w[admin unknown])
  end

  test "known removes duplicates" do
    assert_equal [ "admin" ], Role.known(%w[admin admin])
  end

  test "known returns roles in definition order regardless of input order" do
    assert_equal Role::NAMES, Role.known(Role::NAMES.reverse)
  end

  test "known ignores non-string elements" do
    assert_equal [ "admin" ], Role.known([ "admin", nil, 1, :member, { "a" => 1 }, [ "member" ] ])
  end

  test "known returns an empty array for empty or nil input" do
    assert_equal [], Role.known([])
    assert_equal [], Role.known(nil)
  end

  test "known is case sensitive" do
    assert_equal [], Role.known(%w[Admin ADMIN])
  end

  test "known does not accept a non-array value" do
    assert_equal [], Role.known("admin")
  end
end
