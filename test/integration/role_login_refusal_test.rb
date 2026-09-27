require "test_helper"

# Task 5.1: refusing sign-in because of roles, end to end (real strategy against
# the WebMock IdP stub; no network). Requirements 2.2, 6.1-6.4, 7.1-7.3, 7.5,
# 8.1-8.4.
class RoleLoginRefusalTest < ActionDispatch::IntegrationTest
  include OidcSignInFlow
  include AuthorizationProbe

  GUID_ADMIN = "aaaaaaaa-0000-0000-0000-000000000001".freeze
  GROUP_MAP = { GUID_ADMIN => "admin" }.freeze
  OVERAGE = { _claim_names: { groups: "src1" }, _claim_sources: { src1: { endpoint: "https://graph.invalid/x" } } }.freeze
  FakeIdentity = Struct.new(:claims)

  def user
    User.find_by!(oid: @oid)
  end

  # --- 2.2 / 6.4: assignments change between sign-ins -----------------------

  test "a changed assignment is picked up at the next sign-in" do
    complete_flow(claims: { roles: %w[admin] })
    assert_signed_in
    assert_equal %w[admin], user.roles
    sign_out :user

    complete_flow(claims: { roles: %w[member] })
    assert_signed_in
    assert_equal %w[member], user.roles
  end

  test "after every assignment is revoked the next sign-in is refused" do
    complete_flow(claims: { roles: %w[admin member] })
    assert_signed_in
    sign_out :user

    complete_flow(claims: { roles: [] })
    assert_refused_at_login(I18n.t("authorization.rejections.no_roles"))
    assert_equal [], user.roles
  end

  test "a refused user can try again and succeed once a role is assigned" do
    complete_flow(claims: {})
    assert_refused_at_login(I18n.t("authorization.rejections.no_roles"))

    complete_flow(claims: { roles: %w[member] })
    assert_signed_in
    assert_equal %w[member], user.roles
  end

  # --- 6.1 / 6.2 / 7.1 / 7.2 / 8.1: what the user sees ----------------------

  test "the no_roles refusal shows only its own message" do
    complete_flow(claims: {})
    assert_refused_at_login(I18n.t("authorization.rejections.no_roles"))
    assert_not_includes response.body, ERB::Util.html_escape(I18n.t("authorization.rejections.groups_overage"))
  end

  test "the overage refusal shows only its own message" do
    with_role_source("groups", GROUP_MAP) do
      complete_flow(claims: OVERAGE)
      assert_refused_at_login(I18n.t("authorization.rejections.groups_overage"))
      assert_not_includes response.body, ERB::Util.html_escape(I18n.t("authorization.rejections.no_roles"))
    end
  end

  test "the messages differ between the two reasons" do
    assert_not_equal I18n.t("authorization.rejections.no_roles"), I18n.t("authorization.rejections.groups_overage")
  end

  test "the refusal page shows no claim contents, group IDs, role names or the user's identifiers" do
    with_role_source("groups", GROUP_MAP) do
      complete_flow(claims: OVERAGE.merge(groups: [ "SENTINEL-GROUP" ], roles: [ "SENTINEL-ROLE" ]))
      follow_redirect!
      assert_no_match(/SENTINEL|graph\.invalid|src1/, response.body)
      assert_not_includes response.body, @oid
    end
  end

  test "the refusal is shown in the current locale" do
    I18n.with_locale(:ja) do
      complete_flow(claims: {})
      follow_redirect!
      assert_includes response.body, ERB::Util.html_escape(I18n.t("authorization.rejections.no_roles", locale: :ja))
    end
  end

  # --- 7.5: overage only matters for the groups method ------------------------

  test "roles method: an overage-shaped token with a role signs in" do
    complete_flow(claims: OVERAGE.merge(roles: %w[admin]))
    assert_signed_in
    assert_equal %w[admin], user.roles
  end

  test "roles method: an overage-shaped token without a role is refused as no_roles, not as overage" do
    complete_flow(claims: OVERAGE)
    assert_refused_at_login(I18n.t("authorization.rejections.no_roles"))
  end

  # --- 6.3 / 7.3: no leftover permissions after a refusal -------------------

  test "an open session loses its permissions once a sign-in for the same user is refused (no roles)" do
    draw_authorization_probe_routes
    existing = User.create!(tid: OidcProviderStub::FAKE_TENANT_ID, oid: @oid, roles: %w[admin])
    sign_in existing
    get "/probe/read"
    assert_response :success

    refuse_through_gate(existing, {})

    get "/probe/read"
    assert_response :forbidden
    assert_equal [], existing.reload.roles
  end

  test "an open session loses its permissions once a sign-in for the same user is refused (overage)" do
    draw_authorization_probe_routes
    existing = User.create!(tid: OidcProviderStub::FAKE_TENANT_ID, oid: @oid, roles: %w[admin])
    sign_in existing
    get "/probe/read"
    assert_response :success

    with_role_source("groups", GROUP_MAP) do
      decision = refuse_through_gate(existing, "_claim_names" => { "groups" => "src1" })
      assert_equal :groups_overage, decision.reason
    end

    get "/probe/read"
    assert_response :forbidden
  end

  test "a refused sign-in creates no session" do
    complete_flow(claims: {})
    assert_response :redirect
    assert_redirected_to new_user_session_url
    get "/"
    assert_redirected_to new_user_session_url
  end

  # --- 8.4: the operator can see why -----------------------------------------

  test "a refusal is logged with the reason and the user id, and nothing from the claims" do
    log = captured_log { complete_flow(claims: { roles: %w[SENTINEL-ROLE], groups: %w[SENTINEL-GROUP] }) }
    assert_match(/\[authorization\] login rejected reason=no_roles user_id=#{user.id}\b/, log)
    assert_no_match(/SENTINEL/, log)
  end

  test "an overage refusal is logged with its own reason" do
    with_role_source("groups", GROUP_MAP) do
      log = captured_log { complete_flow(claims: OVERAGE) }
      assert_match(/login rejected reason=groups_overage user_id=#{user.id}\b/, log)
      assert_no_match(/graph\.invalid|src1/, log)
    end
  end

  test "a successful sign-in is not logged as a refusal" do
    log = captured_log { complete_flow(claims: { roles: %w[admin] }) }
    assert_no_match(/login rejected/, log)
  end

  private

  # The same evaluation authentication performs before it would sign anyone in.
  def refuse_through_gate(user, claims)
    decision = EntraAuth::SignInGate.evaluate(FakeIdentity.new(claims), user)
    assert decision.rejected?
    decision
  end
end
