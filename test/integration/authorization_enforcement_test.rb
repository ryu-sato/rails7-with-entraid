require "test_helper"

# Task 5.2: permissions follow the stored roles, in controllers and in views.
# Uses the test-only probe controller (never routed in the app). Requirements
# 9.2-9.6, 10.1, 10.2, 10.4.
class AuthorizationEnforcementTest < ActionDispatch::IntegrationTest
  include OidcSignInFlow
  include AuthorizationProbe

  setup do
    draw_authorization_probe_routes
    # Permissions are under test here, not CSRF (OidcSignInFlow enables it and restores it in teardown).
    ActionController::Base.allow_forgery_protection = false
  end

  def update_probe
    patch "/probe/update"
  end

  # --- 9.3 / 9.5 / 10.1 / 10.2: controllers -----------------------------------

  test "admin may read and update" do
    sign_in create_user_with_roles("admin")
    get "/probe/read"
    assert_response :success
    update_probe
    assert_response :success
    assert_equal [ :update ], AuthorizationProbeController.performed
  end

  test "member may read but not update, and the refused update has no effect" do
    sign_in create_user_with_roles("member")
    get "/probe/read"
    assert_response :success
    update_probe
    assert_response :forbidden
    assert_empty AuthorizationProbeController.performed
  end

  test "repeated refused attempts never produce an effect" do
    sign_in create_user_with_roles("member")
    3.times do
      update_probe
      assert_response :forbidden
    end
    assert_empty AuthorizationProbeController.performed
  end

  # --- 9.2: several roles ------------------------------------------------------

  test "a user with several roles gets what any one of them allows" do
    sign_in create_user_with_roles("member", "admin")
    update_probe
    assert_response :success
  end

  test "an undefined role next to a defined one adds nothing" do
    sign_in create_user_with_roles("ghost", "member")
    get "/probe/read"
    assert_response :success
    update_probe
    assert_response :forbidden
  end

  # --- 9.6: a session that outlives its roles ---------------------------------

  test "a signed-in user without any role is allowed nothing" do
    sign_in create_user_with_roles
    get "/probe/read"
    assert_response :forbidden
    update_probe
    assert_response :forbidden
    get "/probe/links"
    assert_equal "NO-UPDATE|NO-READ", response.body
    assert_empty AuthorizationProbeController.performed
  end

  test "only undefined roles are allowed nothing" do
    sign_in create_user_with_roles("ghost")
    get "/probe/read"
    assert_response :forbidden
  end

  test "permissions follow the stored roles: a change is effective on the next request" do
    user = create_user_with_roles("admin")
    sign_in user
    update_probe
    assert_response :success

    user.update!(roles: %w[member])
    update_probe
    assert_response :forbidden

    user.update!(roles: [])
    get "/probe/read"
    assert_response :forbidden

    user.update!(roles: %w[admin])
    update_probe
    assert_response :success
  end

  # --- 9.4: views ---------------------------------------------------------------

  test "a view can show or hide parts according to what the user may do" do
    {
      %w[admin] => "CAN-UPDATE|CAN-READ",
      %w[member] => "NO-UPDATE|CAN-READ",
      %w[member admin] => "CAN-UPDATE|CAN-READ",
      [] => "NO-UPDATE|NO-READ"
    }.each do |roles, expected|
      sign_out :user
      sign_in create_user_with_roles(*roles)
      get "/probe/links"
      assert_response :success
      assert_equal expected, response.body, "roles #{roles.inspect}"
    end
  end

  # --- 10.4: signed out ----------------------------------------------------------

  test "signed out: protected pages go to sign-in, never to 403" do
    get "/probe/read"
    assert_redirected_to new_user_session_url
    get "/probe/links"
    assert_redirected_to new_user_session_url
  end

  test "signed out on a page that reaches the permission check: sign-in, not 403" do
    get "/probe/open"
    assert_redirected_to new_user_session_url
  end

  # --- from the ID token to a permission, through the real sign-in ------------

  test "a role in the ID token becomes a permission for the signed-in user" do
    complete_flow(claims: { roles: %w[admin] })
    assert_signed_in
    update_probe
    assert_response :success
    assert_equal [ :update ], AuthorizationProbeController.performed
  end

  test "a read-only role in the ID token cannot update" do
    complete_flow(claims: { roles: %w[member] })
    assert_signed_in
    get "/probe/read"
    assert_response :success
    update_probe
    assert_response :forbidden
    assert_empty AuthorizationProbeController.performed
  end

  test "under the groups method a mapped group becomes a permission" do
    with_role_source("groups", "aaaaaaaa-0000-0000-0000-000000000001" => "admin") do
      complete_flow(claims: { groups: %w[aaaaaaaa-0000-0000-0000-000000000001] })
      assert_signed_in
      update_probe
      assert_response :success
    end
  end
end
