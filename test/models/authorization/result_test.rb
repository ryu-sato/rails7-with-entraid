require "test_helper"

class Authorization::ResultTest < ActiveSupport::TestCase
  Result = Authorization::Result

  test "Candidates holds role names" do
    assert_equal %w[admin], Result::Candidates.new(names: %w[admin]).names
    assert_equal [], Result::Candidates.new(names: []).names
  end

  test "Synced holds a non-empty list of roles" do
    assert_equal %w[admin], Result::Synced.new(roles: %w[admin]).roles
    assert_raises(ArgumentError) { Result::Synced.new(roles: []) }
  end

  test "Rejected accepts only the known reasons" do
    assert_equal :no_roles, Result::Rejected.new(reason: :no_roles).reason
    assert_equal :groups_overage, Result::Rejected.new(reason: :groups_overage).reason
    assert_raises(ArgumentError) { Result::Rejected.new(reason: :something_else) }
    assert_raises(ArgumentError) { Result::Rejected.new(reason: "no_roles") }
  end

  test "the three types are distinct" do
    types = [ Result::Candidates.new(names: []), Result::Synced.new(roles: %w[admin]), Result::Rejected.new(reason: :no_roles) ]
    assert_equal 3, types.map(&:class).uniq.size
  end

  test "REASONS lists every rejection reason" do
    assert_equal %i[no_roles groups_overage], Result::REASONS
  end
end
