require "test_helper"

class Authorization::SignInGateAdapterTest < ActiveSupport::TestCase
  include AuthorizationGate

  GUID_ADMIN = "aaaaaaaa-0000-0000-0000-000000000001".freeze
  OVERAGE = { "_claim_names" => { "groups" => "src1" } }.freeze

  FakeIdentity = Struct.new(:claims)

  def create_user(*roles)
    User.create!(tid: "tenant-1", oid: SecureRandom.uuid, roles: roles)
  end

  def call(user, claims)
    Authorization::SignInGateAdapter.call(FakeIdentity.new(claims), user)
  end

  test "a user with a role is accepted and the roles are stored" do
    user = create_user
    decision = call(user, "roles" => %w[admin])
    assert decision.accepted?
    assert_nil decision.reason
    assert_equal %w[admin], user.reload.roles
  end

  test "a user without roles is rejected with the no_roles message" do
    user = create_user("admin")
    decision = call(user, {})
    assert decision.rejected?
    assert_equal :no_roles, decision.reason
    assert_equal I18n.t("authorization.rejections.no_roles"), decision.message
    assert_equal [], user.reload.roles
  end

  test "under the groups method an overage is rejected with its own message" do
    with_role_source("groups", GUID_ADMIN => "admin") do
      decision = call(create_user, OVERAGE)
      assert decision.rejected?
      assert_equal :groups_overage, decision.reason
      assert_equal I18n.t("authorization.rejections.groups_overage"), decision.message
    end
  end

  test "the two rejection messages differ" do
    with_role_source("groups", GUID_ADMIN => "admin") do
      assert_not_equal call(create_user, {}).message, call(create_user, OVERAGE).message
    end
  end

  test "the message follows the current locale" do
    I18n.with_locale(:ja) do
      assert_equal I18n.t("authorization.rejections.no_roles", locale: :ja), call(create_user, {}).message
    end
  end

  test "a rejection message carries no claim contents, role names or identifiers" do
    user = create_user
    decision = call(user, "roles" => %w[SENTINEL-ROLE], "groups" => %w[SENTINEL-GUID])
    assert_no_match(/SENTINEL/, decision.message)
    assert_not_includes decision.message, user.oid
  end

  test "the app registers exactly one gate at boot, and it is this adapter" do
    assert_equal 1, AuthorizationGate::BOOT_GATES.size

    user = create_user
    decision = AuthorizationGate::BOOT_GATES.first.call(FakeIdentity.new({ "roles" => %w[member] }), user)
    assert decision.accepted?
    assert_equal %w[member], user.reload.roles
  end

  test "through the registry: accepted, and rejected with the fixed message" do
    register_authorization_gate

    accepted = EntraAuth::SignInGate.evaluate(FakeIdentity.new({ "roles" => %w[admin] }), create_user)
    assert accepted.accepted?

    rejected = EntraAuth::SignInGate.evaluate(FakeIdentity.new({}), create_user)
    assert rejected.rejected?
    assert_equal :no_roles, rejected.reason
    assert_equal I18n.t("authorization.rejections.no_roles"), rejected.message
  end

  test "a misconfigured role source fails closed through the registry" do
    register_authorization_gate
    with_role_source("saml") do
      decision = EntraAuth::SignInGate.evaluate(FakeIdentity.new({ "roles" => %w[admin] }), create_user)
      assert decision.rejected?
      assert_equal :gate_error, decision.reason
    end
  end
end
