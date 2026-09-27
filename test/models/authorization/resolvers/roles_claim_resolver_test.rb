require "test_helper"

class Authorization::Resolvers::RolesClaimResolverTest < ActiveSupport::TestCase
  def resolve(raw_info)
    Authorization::Resolvers::RolesClaimResolver.new.call(Authorization::Claims.from_raw_info(raw_info))
  end

  test "returns the roles claim values as candidates" do
    result = resolve("roles" => %w[admin member])
    assert_instance_of Authorization::Result::Candidates, result
    assert_equal %w[admin member], result.names
  end

  test "passes values through unfiltered (the common rules are applied by RoleSync)" do
    assert_equal %w[admin ghost admin], resolve("roles" => %w[admin ghost admin]).names
  end

  test "no roles claim gives empty candidates" do
    assert_equal [], resolve({}).names
  end

  test "an empty roles claim gives empty candidates" do
    assert_equal [], resolve("roles" => []).names
  end

  test "only undefined values are still returned as candidates" do
    assert_equal %w[ghost], resolve("roles" => %w[ghost]).names
  end

  test "ignores the groups claim even when it is present" do
    assert_equal [], resolve("groups" => %w[g-1 g-2]).names
    assert_equal %w[admin], resolve("roles" => %w[admin], "groups" => %w[g-1]).names
  end

  test "an overage-shaped token does not change the result and is never a rejection" do
    result = resolve("roles" => %w[admin], "_claim_names" => { "groups" => "src1" })
    assert_instance_of Authorization::Result::Candidates, result
    assert_equal %w[admin], result.names
  end
end
