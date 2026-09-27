require "test_helper"

class Authorization::Resolvers::GroupsClaimResolverTest < ActiveSupport::TestCase
  GUID_ADMIN = "aaaaaaaa-0000-0000-0000-000000000001".freeze
  GUID_MEMBER = "bbbbbbbb-0000-0000-0000-000000000002".freeze
  GUID_OTHER = "cccccccc-0000-0000-0000-000000000003".freeze

  MAP = { GUID_ADMIN => "admin", GUID_MEMBER => "member" }.freeze

  def resolve(raw_info, map = MAP)
    Authorization::Resolvers::GroupsClaimResolver.new(group_role_map: map)
                                                 .call(Authorization::Claims.from_raw_info(raw_info))
  end

  test "maps a listed group to its role" do
    result = resolve("groups" => [ GUID_ADMIN ])
    assert_instance_of Authorization::Result::Candidates, result
    assert_equal [ "admin" ], result.names
  end

  test "maps several groups to several roles" do
    assert_equal %w[admin member], resolve("groups" => [ GUID_ADMIN, GUID_MEMBER ]).names
  end

  test "ignores groups that are not in the map" do
    assert_equal [ "member" ], resolve("groups" => [ GUID_OTHER, GUID_MEMBER ]).names
    assert_equal [], resolve("groups" => [ GUID_OTHER ]).names
  end

  test "GUID matching ignores case" do
    assert_equal [ "admin" ], resolve("groups" => [ GUID_ADMIN.upcase ]).names
    assert_equal [ "admin" ], resolve({ "groups" => [ GUID_ADMIN ] }, { GUID_ADMIN.upcase => "admin" }).names
  end

  test "several groups mapped to the same role give that role each time (deduplication is RoleSync's job)" do
    map = { GUID_ADMIN => "admin", GUID_OTHER => "admin" }
    assert_equal %w[admin admin], resolve({ "groups" => [ GUID_ADMIN, GUID_OTHER ] }, map).names
  end

  test "passes a mapped undefined role through as a candidate (RoleSync drops it)" do
    assert_equal [ "ghost" ], resolve({ "groups" => [ GUID_ADMIN ] }, { GUID_ADMIN => "ghost" }).names
  end

  test "no groups claim and no overage gives empty candidates" do
    assert_equal [], resolve({}).names
    assert_equal [], resolve("groups" => []).names
  end

  test "an empty map gives empty candidates" do
    assert_equal [], resolve({ "groups" => [ GUID_ADMIN ] }, {}).names
  end

  test "ignores the roles claim" do
    assert_equal [], resolve("roles" => %w[admin]).names
    assert_equal [ "member" ], resolve("roles" => %w[admin], "groups" => [ GUID_MEMBER ]).names
  end

  test "overage is rejected with groups_overage" do
    result = resolve("_claim_names" => { "groups" => "src1" }, "_claim_sources" => { "src1" => { "endpoint" => "https://graph.invalid/x" } })
    assert_instance_of Authorization::Result::Rejected, result
    assert_equal :groups_overage, result.reason
  end

  test "overage is decided before the groups claim is looked at" do
    result = resolve("_claim_names" => { "groups" => "src1" }, "groups" => [ GUID_ADMIN ])
    assert_instance_of Authorization::Result::Rejected, result
    assert_equal :groups_overage, result.reason
  end

  test "resolving makes no network call" do
    WebMock.disable_net_connect!
    assert_nothing_raised do
      resolve("_claim_names" => { "groups" => "src1" }, "_claim_sources" => { "src1" => { "endpoint" => "https://graph.invalid/x" } })
      resolve("groups" => [ GUID_ADMIN ])
    end
    assert_not_requested :any, /.*/
  end

  test "the map is copied so later changes to it do not affect the resolver" do
    map = { GUID_ADMIN => "admin" }
    resolver = Authorization::Resolvers::GroupsClaimResolver.new(group_role_map: map)
    map.clear
    names = resolver.call(Authorization::Claims.from_raw_info("groups" => [ GUID_ADMIN ])).names
    assert_equal [ "admin" ], names
  end
end
