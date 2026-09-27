require "test_helper"

class Authorization::ClaimsTest < ActiveSupport::TestCase
  Claims = Authorization::Claims

  test "extracts roles and groups as string arrays" do
    claims = Claims.from_raw_info("roles" => %w[admin member], "groups" => %w[g-1 g-2])
    assert_equal %w[admin member], claims.roles
    assert_equal %w[g-1 g-2], claims.groups
    assert_not claims.groups_overage?
  end

  test "missing keys give empty values" do
    claims = Claims.from_raw_info({})
    assert_equal [], claims.roles
    assert_equal [], claims.groups
    assert_not claims.groups_overage?
  end

  test "a nil or non-hash raw_info gives empty claims" do
    [ nil, "string", 1, [] ].each do |raw|
      claims = Claims.from_raw_info(raw)
      assert_equal [], claims.roles
      assert_equal [], claims.groups
      assert_not claims.groups_overage?
    end
  end

  test "values of an unexpected type are treated as empty" do
    claims = Claims.from_raw_info("roles" => "admin", "groups" => { "a" => 1 })
    assert_equal [], claims.roles
    assert_equal [], claims.groups
  end

  test "non-string elements are dropped" do
    claims = Claims.from_raw_info("roles" => [ "admin", nil, 1, :member, [ "x" ] ], "groups" => [ "g-1", 2, nil ])
    assert_equal [ "admin" ], claims.roles
    assert_equal [ "g-1" ], claims.groups
  end

  test "groups overage is detected from _claim_names naming groups" do
    claims = Claims.from_raw_info("_claim_names" => { "groups" => "src1" }, "_claim_sources" => { "src1" => { "endpoint" => "https://example.invalid" } })
    assert claims.groups_overage?
    assert_equal [], claims.groups
  end

  test "_claim_names without groups is not an overage" do
    assert_not Claims.from_raw_info("_claim_names" => { "other" => "src1" }).groups_overage?
  end

  test "a non-hash _claim_names is not an overage" do
    [ "groups", [ "groups" ], nil ].each do |value|
      assert_not Claims.from_raw_info("_claim_names" => value).groups_overage?
    end
  end

  test "works with the OmniAuth AuthHash form (Hashie::Mash, string keys)" do
    auth = OmniAuth::AuthHash.new(extra: { raw_info: { "roles" => [ "admin" ], "groups" => [ "g-1" ], "_claim_names" => { "groups" => "src1" } } })
    claims = Claims.from_raw_info(auth.extra.raw_info)
    assert_equal [ "admin" ], claims.roles
    assert_equal [ "g-1" ], claims.groups
    assert claims.groups_overage?
  end

  test "symbol keys are read the same way" do
    claims = Claims.from_raw_info(roles: [ "admin" ], groups: [ "g-1" ], _claim_names: { groups: "src1" })
    assert_equal [ "admin" ], claims.roles
    assert_equal [ "g-1" ], claims.groups
    assert claims.groups_overage?
  end

  test "keeps nothing beyond roles, groups and the overage flag" do
    claims = Claims.from_raw_info(
      "roles" => [ "admin" ], "groups" => [ "g-1" ], "email" => "a@example.com", "name" => "Alice",
      "preferred_username" => "alice", "_claim_sources" => { "src1" => { "endpoint" => "x" } }
    )
    assert_equal %i[@groups @groups_overage @roles], claims.instance_variables.sort
  end

  test "inspect and to_s do not reveal claim contents" do
    claims = Claims.from_raw_info("roles" => [ "SENTINEL-ROLE" ], "groups" => [ "SENTINEL-GROUP-GUID" ])
    [ claims.inspect, claims.to_s, "#{claims}", claims.pretty_inspect ].each do |text|
      assert_no_match(/SENTINEL/, text)
    end
  end

  test "the returned arrays cannot be used to change the claims" do
    claims = Claims.from_raw_info("roles" => [ "admin" ])
    assert claims.roles.frozen?
    assert claims.groups.frozen?
  end

  test "does not mutate the given raw_info" do
    raw = { "roles" => [ "admin" ] }.freeze
    assert_nothing_raised { Claims.from_raw_info(raw) }
  end
end
