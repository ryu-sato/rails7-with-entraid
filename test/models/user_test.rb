require "test_helper"

class UserTest < ActiveSupport::TestCase
  TID = "11111111-2222-3333-4444-555555555555".freeze
  OTHER_TID = "22222222-2222-3333-4444-555555555555".freeze
  OID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".freeze
  OTHER_OID = "99999999-bbbb-cccc-dddd-eeeeeeeeeeee".freeze

  def identity(tid: TID, oid: OID, **claims)
    raw = { "oid" => oid, "tid" => tid, "name" => "Taro Yamada", "email" => "taro@example.com" }
    claims.each { |k, v| raw[k.to_s] = v }
    raw.compact!
    auth = OmniAuth::AuthHash.new(provider: "entra", uid: "sub", extra: { raw_info: raw })
    EntraAuth::VerifiedIdentity.from_auth_hash(auth, expected_tenant_id: tid)
  end

  test "has only the sign-in and expiry Devise modules" do
    modules = User.devise_modules
    assert_includes modules, :omniauthable
    assert_includes modules, :timeoutable
    assert_equal [ :omniauthable, :timeoutable ], modules.sort
    %i[database_authenticatable rememberable recoverable registerable validatable].each do |m|
      assert_not_includes modules, m
    end
    assert_equal [ :openid_connect ], User.omniauth_providers
    user = User.new
    %i[password remember_me remember_created_at].each { |m| assert_not user.respond_to?(m), "must not respond to #{m}" }
  end

  test "from_identity creates a user on first sign-in with normalized tid/oid" do
    user = nil
    assert_difference("User.count", 1) do
      user = User.from_identity(identity(tid: TID.upcase, oid: OID.upcase))
    end
    assert user.persisted?
    assert_equal TID, user.tid
    assert_equal OID, user.oid
    assert_equal "Taro Yamada", user.name
    assert_equal "taro@example.com", user.email
  end

  test "from_identity returns the same record for the same (tid, oid)" do
    first = User.from_identity(identity)
    second = nil
    assert_no_difference("User.count") { second = User.from_identity(identity(oid: OID.upcase)) }
    assert_equal first.id, second.id
  end

  test "from_identity updates name and email but never tid/oid" do
    first = User.from_identity(identity)
    assert_no_difference("User.count") do
      User.from_identity(identity(name: "Taro Renamed", email: "new@example.com"))
    end
    first.reload
    assert_equal "Taro Renamed", first.name
    assert_equal "new@example.com", first.email
    assert_equal TID, first.tid
    assert_equal OID, first.oid
  end

  test "an email change is treated as the same person" do
    a = User.from_identity(identity(email: "old@example.com"))
    b = User.from_identity(identity(email: "changed@example.com"))
    assert_equal a.id, b.id
    assert_equal 1, User.count
  end

  test "absent name/email are stored as nil and overwrite earlier values (display-only mirrors)" do
    created = User.from_identity(identity(name: nil, email: nil))
    assert created.persisted?
    assert_nil created.email
    assert_nil created.name
    User.from_identity(identity)
    assert_equal "taro@example.com", created.reload.email
    User.from_identity(identity(email: nil, name: nil))
    assert_nil created.reload.email
    assert_nil created.reload.name
  end

  test "the same oid in a different tenant is a different user" do
    a = User.from_identity(identity)
    b = User.from_identity(identity(tid: OTHER_TID))
    assert_not_equal a.id, b.id
    assert_equal 2, User.count
  end

  test "different oid in the same tenant is a different user" do
    a = User.from_identity(identity)
    b = User.from_identity(identity(oid: OTHER_OID))
    assert_not_equal a.id, b.id
  end

  test "recovers from a create race by re-fetching (RecordNotUnique)" do
    existing = User.create!(tid: TID, oid: OID, name: "Other", email: nil)
    calls = 0
    original = User.method(:find_by)
    User.singleton_class.define_method(:find_by) do |*args, **kw, &blk|
      calls += 1
      calls == 1 ? nil : original.call(*args, **kw, &blk)
    end
    begin
      result = nil
      assert_no_difference("User.count") { result = User.from_identity(identity) }
      assert_equal existing.id, result.id
      assert_equal "Taro Yamada", result.reload.name
      assert_operator calls, :>=, 2
    ensure
      User.singleton_class.send(:remove_method, :find_by)
    end
  end

  test "DB-level uniqueness on (tid, oid) holds" do
    User.create!(tid: TID, oid: OID)
    assert_raises(ActiveRecord::RecordNotUnique) do
      User.new(tid: TID, oid: OID).save!(validate: false)
    end
    assert_raises(ActiveRecord::RecordNotUnique) do
      User.insert_all!([ { tid: TID, oid: OID } ])
    end
  end

  test "Devise session round-trip finds the user by primary key only" do
    user = User.from_identity(identity)
    assert_nil user.authenticatable_salt
    key = User.serialize_into_session(user)
    assert_equal user, User.serialize_from_session(*key)
    assert_nil User.serialize_from_session(user.id + 1000, nil)
  end

  test "active_for_authentication defaults are untouched" do
    user = User.from_identity(identity)
    assert user.active_for_authentication?
    assert_equal :inactive, user.inactive_message
  end

  test "timedout? follows Devise.timeout_in" do
    user = User.from_identity(identity)
    assert_equal EntraAuth::Config.idle_timeout, Devise.timeout_in
    assert_not user.timedout?(nil)
    assert_not user.timedout?(Devise.timeout_in.ago + 5.seconds)
    assert user.timedout?(Devise.timeout_in.ago - 5.seconds)
  end

  test "attributes and inspect carry nothing token-like" do
    assert_equal %w[created_at email id name oid tid updated_at], User.column_names.sort
    user = User.from_identity(identity(access_token: "SENTINEL-TOKEN", id_token: "SENTINEL-ID"))
    assert_no_match(/token|SENTINEL/i, user.inspect)
    assert_no_match(/token|SENTINEL/i, user.attributes.keys.join)
  end
end
