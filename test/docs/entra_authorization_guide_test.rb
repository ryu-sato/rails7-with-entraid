require "test_helper"

# Keeps docs/entra-authorization.md in step with the implementation
# (requirements 11.1-11.6): setting names, values and the topics operators need.
class EntraAuthorizationGuideTest < ActiveSupport::TestCase
  GUIDE = Rails.root.join("docs/entra-authorization.md")

  def guide = @guide ||= GUIDE.read

  test "the guide exists" do
    assert GUIDE.file?
  end

  test "it names the real setting keys and values" do
    assert_includes guide, "authorization.role_source"
    assert_includes guide, "group_role_map"
    Authorization::RoleSource::SOURCES.each { |source| assert_includes guide, "`#{source}`", "value #{source} is not documented" }
  end

  test "the settings it documents exist in the settings files" do
    shared = YAML.load_file(Rails.root.join("config/settings.yml"))
    assert shared.fetch("authorization").key?("group_role_map")
    assert_not shared.fetch("authorization").key?("role_source"), "role_source must have no shared default"
    %w[development test production].each do |env|
      settings = YAML.load_file(Rails.root.join("config/settings/#{env}.yml"))
      assert_includes Authorization::RoleSource::SOURCES, settings.dig("authorization", "role_source"), "#{env} must set role_source"
    end
  end

  test "it points to the role definition and the ability file that exist" do
    assert_includes guide, "Role::NAMES"
    assert_includes guide, "app/models/role.rb"
    assert_includes guide, "app/models/ability.rb"
    assert Rails.root.join("app/models/role.rb").file?
    assert Rails.root.join("app/models/ability.rb").file?
  end

  test "it names the session limit that bounds how stale roles can get, as the app defines it" do
    variable = EntraAuth::Config::ENV_KEYS.fetch(:absolute_hours)
    assert_includes guide, variable
  end

  test "it documents the log line the app writes on a refusal" do
    assert_includes guide, "[authorization] login rejected reason="
    Authorization::Result::REASONS.each { |reason| assert_includes guide, "`#{reason}`" }
  end

  test "11.1 roles method prerequisites" do
    [ "アプリ ロール", "割り当てが必要ですか", "ユーザーとグループ", "完全一致" ].each { |text| assert_includes guide, text }
  end

  test "11.2 groups method prerequisites" do
    [ "セキュリティ グループ", "グループ ID", "オブジェクト ID", "group_role_map" ].each { |text| assert_includes guide, text }
  end

  test "11.3 groups method constraint: overage and the pre-check" do
    [ "overage", "200", "事前確認" ].each { |text| assert_includes guide, text }
  end

  test "11.4 roles method does not reflect group hierarchy" do
    assert_match(/グループの階層構造は反映されません/, guide)
  end

  test "11.5 how to choose between the methods" do
    [ "テナントの契約種別", "P1 / P2", "Free" ].each { |text| assert_includes guide, text }
  end

  test "11.6 roles change only at sign-in, and the delay limit" do
    assert_match(/ログイン時にだけ/, guide)
    assert_match(/絶対時間上限/, guide)
  end
end
