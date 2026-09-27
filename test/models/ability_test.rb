require "test_helper"

class AbilityTest < ActiveSupport::TestCase
  def user_with(roles)
    User.new(tid: "t", oid: SecureRandom.uuid, roles: roles)
  end

  def ability_for(roles)
    Ability.new(user_with(roles))
  end

  test "a missing user is allowed nothing" do
    ability = Ability.new(nil)
    assert ability.cannot?(:read, :anything)
    assert ability.cannot?(:manage, :all)
  end

  test "a user without roles is allowed nothing" do
    ability = ability_for([])
    %i[read create update destroy manage].each do |action|
      assert ability.cannot?(action, :anything), "#{action} should be denied"
    end
  end

  test "admin may do everything" do
    ability = ability_for(%w[admin])
    %i[read create update destroy manage].each do |action|
      assert ability.can?(action, :anything), "#{action} should be allowed"
    end
  end

  test "member may only read" do
    ability = ability_for(%w[member])
    assert ability.can?(:read, :anything)
    assert ability.cannot?(:update, :anything)
    assert ability.cannot?(:destroy, :anything)
    assert ability.cannot?(:manage, :all)
  end

  test "several roles give the union of what each allows" do
    ability = ability_for(%w[member admin])
    assert ability.can?(:read, :anything)
    assert ability.can?(:destroy, :anything)
  end

  test "roles that are no longer defined in code allow nothing" do
    assert ability_for(%w[ghost]).cannot?(:read, :anything)
  end

  test "an undefined role stored next to a defined one does not widen access" do
    ability = ability_for(%w[ghost member])
    assert ability.can?(:read, :anything)
    assert ability.cannot?(:update, :anything)
  end

  test "role names are matched exactly" do
    assert ability_for(%w[Admin ADMIN]).cannot?(:read, :anything)
  end

  test "malformed stored roles allow nothing and do not raise" do
    [ nil, "admin", [ nil, 1 ] ].each do |roles|
      user = User.new(tid: "t", oid: "o")
      user.define_singleton_method(:roles) { roles }
      ability = nil
      assert_nothing_raised { ability = Ability.new(user) }
      assert ability.cannot?(:read, :anything)
    end
  end

  test "every defined role has its own rules" do
    Role::NAMES.each do |name|
      assert Ability.private_method_defined?("#{name}_rules"), "Ability has no #{name}_rules"
    end
  end

  test "abilities are decided from the user's stored roles" do
    user = User.create!(tid: "t", oid: SecureRandom.uuid, roles: %w[member])
    assert Ability.new(user).cannot?(:update, :anything)

    user.update!(roles: %w[admin])
    assert Ability.new(user.reload).can?(:update, :anything)

    user.update!(roles: [])
    assert Ability.new(user.reload).cannot?(:read, :anything)
  end
end
