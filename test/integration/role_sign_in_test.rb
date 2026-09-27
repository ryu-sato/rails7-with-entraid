require "test_helper"

# Task 4.1: roles are taken from the ID token during the real sign-in flow, and a
# user without a usable role never gets a session. Requirements 2.1, 6.1, 6.2,
# 7.1, 7.2, 8.1, 8.3.
class RoleSignInTest < ActionDispatch::IntegrationTest
  include OidcSignInFlow

  GUID_ADMIN = "aaaaaaaa-0000-0000-0000-000000000001".freeze
  GUID_MEMBER = "bbbbbbbb-0000-0000-0000-000000000002".freeze
  GROUP_MAP = { GUID_ADMIN => "admin", GUID_MEMBER => "member" }.freeze
  OVERAGE = { _claim_names: { groups: "src1" }, _claim_sources: { src1: { endpoint: "https://graph.invalid/users/x/getMemberObjects" } } }.freeze

  test "roles method: a user with an assigned role signs in and the role is stored" do
    complete_flow(claims: { roles: %w[admin] })
    assert_signed_in
    assert_equal %w[admin], User.find_by!(oid: @oid).roles
  end

  test "roles method: signing in again replaces the stored roles" do
    complete_flow(claims: { roles: %w[admin] })
    assert_signed_in
    sign_out :user

    complete_flow(claims: { roles: %w[member] })
    assert_signed_in
    assert_equal %w[member], User.find_by!(oid: @oid).roles
  end

  test "roles method: undefined roles are not stored" do
    complete_flow(claims: { roles: %w[ghost member] })
    assert_signed_in
    assert_equal %w[member], User.find_by!(oid: @oid).roles
  end

  test "roles method: no role means no session, the no_roles message and a way to retry" do
    complete_flow(claims: {})
    assert_refused_at_login(I18n.t("authorization.rejections.no_roles"))
    assert_equal [], User.find_by!(oid: @oid).roles
  end

  test "roles method: only undefined roles is the same refusal" do
    complete_flow(claims: { roles: %w[ghost] })
    assert_refused_at_login(I18n.t("authorization.rejections.no_roles"))
  end

  test "groups method: a mapped group signs the user in with the mapped role" do
    with_role_source("groups", GROUP_MAP) do
      complete_flow(claims: { groups: [ GUID_MEMBER ] })
      assert_signed_in
      assert_equal %w[member], User.find_by!(oid: @oid).roles
    end
  end

  test "groups method: an overage is refused with its own message" do
    with_role_source("groups", GROUP_MAP) do
      complete_flow(claims: OVERAGE)
      assert_refused_at_login(I18n.t("authorization.rejections.groups_overage"))
      assert_not_includes response.body, I18n.t("authorization.rejections.no_roles")
      assert_equal [], User.find_by!(oid: @oid).roles
    end
  end

  test "groups method: only unmapped groups is refused as no_roles" do
    with_role_source("groups", GROUP_MAP) do
      complete_flow(claims: { groups: [ "cccccccc-0000-0000-0000-000000000003" ] })
      assert_refused_at_login(I18n.t("authorization.rejections.no_roles"))
    end
  end

  test "a refusal never leaks claim contents, identifiers or tokens into the page or the log" do
    with_role_source("groups", GROUP_MAP) do
      log = captured_log { complete_flow(claims: OVERAGE.merge(groups: [ "SENTINEL-GUID" ])) }
      page = response.body
      follow_redirect!
      [ log, page, response.body ].each do |text|
        assert_no_match(/SENTINEL-GUID|graph\.invalid|getMemberObjects|src1/, text)
      end
      assert_match(/login rejected reason=groups_overage/, log)
    end
  end
end
