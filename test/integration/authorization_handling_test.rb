require "test_helper"

# Requirements 9.3, 9.5, 10.1-10.4: what happens when authorize! refuses.
class AuthorizationHandlingTest < ActionDispatch::IntegrationTest
  include AuthorizationProbe

  setup { draw_authorization_probe_routes }

  def forbidden_title(locale = I18n.default_locale)
    I18n.t("authorization.forbidden.title", locale: locale)
  end

  test "a permitted action is performed" do
    sign_in create_user_with_roles("member")
    get "/probe/read"
    assert_response :success
    assert_equal "read-ok", response.body
  end

  test "a refused HTML request gets 403 and the permission-denied screen" do
    sign_in create_user_with_roles("member")
    patch "/probe/update"
    assert_response :forbidden
    assert_includes response.body, forbidden_title
    assert_includes response.body, I18n.t("authorization.forbidden.body")
    assert_select "a[href='#{root_path}']", text: I18n.t("authorization.forbidden.back")
  end

  test "a refused request has no side effect" do
    sign_in create_user_with_roles("member")
    patch "/probe/update"
    assert_response :forbidden
    assert_empty AuthorizationProbeController.performed
  end

  test "the permitted counterpart does have its side effect" do
    sign_in create_user_with_roles("admin")
    patch "/probe/update"
    assert_response :success
    assert_equal [ :update ], AuthorizationProbeController.performed
  end

  test "the permission-denied screen shows nothing internal" do
    sign_in create_user_with_roles("member")
    patch "/probe/update"
    assert_not_includes response.body, "update-ok"
    assert_no_match(/\b(member|admin)\b/i, response.body)
    assert_no_match(/CanCan|AccessDenied|not authorized to access/i, response.body)
    assert_no_match(/:probe|authorization_probe/i, response.body)
  end

  test "the screen follows the current locale" do
    sign_in create_user_with_roles("member")
    I18n.with_locale(:ja) do
      patch "/probe/update"
    end
    assert_response :forbidden
    assert_includes response.body, forbidden_title(:ja)
  end

  test "non-HTML requests get a bare 403" do
    sign_in create_user_with_roles("member")
    patch "/probe/update.json"
    assert_response :forbidden
    assert_predicate response.body, :blank?
  end

  test "a user with no roles is refused everything" do
    sign_in create_user_with_roles
    get "/probe/read"
    assert_response :forbidden
    patch "/probe/update"
    assert_response :forbidden
    assert_empty AuthorizationProbeController.performed
  end

  test "a signed-out request is sent to the sign-in flow, not answered with 403" do
    get "/probe/open"
    assert_redirected_to new_user_session_url
    assert_not_includes response.body, forbidden_title
  end

  test "a protected route still requires sign-in first" do
    get "/probe/read"
    assert_redirected_to new_user_session_url
  end

  test "errors that are not permission refusals are not turned into 403" do
    sign_in create_user_with_roles("admin")
    assert_raises(RuntimeError) { get "/probe/boom" }
  end

  test "the refusal is logged with the user id and the action, without the roles" do
    user = create_user_with_roles("member")
    sign_in user
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    begin
      patch "/probe/update"
    ensure
      Rails.logger = original
    end
    log = io.string
    assert_match(/\[authorization\] access denied user_id=#{user.id} action=authorization_probe#update/, log)
    assert_no_match(/member/, log[/\[authorization\] access denied[^\n]*/])
  end
end
