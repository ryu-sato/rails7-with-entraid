require "test_helper"

# Task 4.3: protected top page and sign-out button.
# Requirements 1.5, 5.1, 7.6 (5.x mechanism is covered by access_protection_test).
class HomeControllerTest < ActionDispatch::IntegrationTest
  include SessionsTestHelpers

  def build_user(name: "Taro Yamada")
    User.create!(tid: EntraAuth::Config.tenant_id, oid: SecureRandom.uuid, name: name, email: "taro@example.com")
  end

  test "signed-in user sees the top page with the escaped name" do
    sign_in build_user(name: "<b>Taro</b> & Co")
    get root_path
    assert_response :success
    assert_includes response.body, "&lt;b&gt;Taro&lt;/b&gt; &amp; Co"
    assert_not_includes response.body, "<b>Taro</b>"
  end

  test "a nil name shows the neutral fallback text" do
    sign_in build_user(name: nil)
    get root_path
    assert_response :success
    assert_includes response.body, I18n.t("home.index.unnamed")
  end

  test "top page has a sign-out button: DELETE form, turbo disabled, with token" do
    sign_in build_user
    with_forgery_protection { get root_path }
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    form = doc.at_css("form[action='#{destroy_user_session_path}']")
    assert form, "expected the sign-out form"
    assert_equal "post", form["method"].downcase
    assert_equal "delete", form.at_css("input[name=_method]")["value"]
    assert_equal "false", form["data-turbo"]
    assert form.at_css("input[name=authenticity_token]")&.[]("value").present?
    assert form.at_css("button, input[type=submit]")
  end

  test "the sign-out button is not rendered on anonymous pages" do
    get new_user_session_path
    assert_response :success
    assert_nil Nokogiri::HTML(response.body).at_css("form[action='#{destroy_user_session_path}']")
    get signed_out_path
    assert_nil Nokogiri::HTML(response.body).at_css("form[action='#{destroy_user_session_path}']")
  end

  test "the layout keeps rendering flash messages" do
    sign_in build_user
    get root_path
    assert_select "p.flash", false
  end

  test "sign-in state persists across requests without contacting Entra ID" do
    sign_in build_user
    get root_path
    assert_response :success
    get root_path
    assert_response :success
    assert_not_requested :any, /.*/
  end

  test "after sign-out a protected page is not served" do
    sign_in build_user
    get root_path
    assert_response :success
    delete destroy_user_session_path
    assert_response :redirect
    get root_path
    assert_redirected_to new_user_session_url
    assert_not_includes response.body, "Taro"
  end

  test "locale files for the home page have identical key sets" do
    ja = YAML.load_file(Rails.root.join("config/locales/home.ja.yml"))["ja"]
    en = YAML.load_file(Rails.root.join("config/locales/home.en.yml"))["en"]
    flat = ->(h, pre = nil) { h.flat_map { |k, v| v.is_a?(Hash) ? flat.(v, [ pre, k ].compact.join(".")) : [ [ pre, k ].compact.join(".") ] } }
    assert_equal flat.(ja).sort, flat.(en).sort
    assert_not_empty flat.(en)
  end
end
