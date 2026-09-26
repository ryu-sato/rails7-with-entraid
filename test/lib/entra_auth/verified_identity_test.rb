require "test_helper"

class EntraAuthVerifiedIdentityTest < ActiveSupport::TestCase
  TID = "11111111-2222-3333-4444-555555555555".freeze
  OID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".freeze
  OTHER_OID = "99999999-bbbb-cccc-dddd-eeeeeeeeeeee".freeze
  ACCESS_TOKEN = "SENTINEL-ACCESS-TOKEN".freeze
  REFRESH_TOKEN = "SENTINEL-REFRESH-TOKEN".freeze
  RAW_ID_TOKEN = "SENTINEL-RAW-ID-TOKEN.aaa.bbb".freeze

  def raw_info(**overrides)
    {
      "oid" => OID, "tid" => TID, "name" => "Taro Yamada",
      "email" => "taro@example.com", "login_hint" => "hint-value",
      "sub" => "subject-value", "iss" => "https://login.microsoftonline.com/#{TID}/v2.0",
      "aud" => "client-id", "nonce" => "n-123"
    }.merge(overrides.transform_keys(&:to_s))
  end

  def auth_hash(info = raw_info)
    OmniAuth::AuthHash.new(
      provider: "entra", uid: "subject-value",
      credentials: { token: ACCESS_TOKEN, refresh_token: REFRESH_TOKEN, id_token: RAW_ID_TOKEN },
      extra: { raw_info: info }
    )
  end

  def build(info = raw_info, tenant: TID)
    EntraAuth::VerifiedIdentity.from_auth_hash(auth_hash(info), expected_tenant_id: tenant)
  end

  def assert_invalid(reason, info = raw_info, tenant: TID)
    error = assert_raises(EntraAuth::VerifiedIdentity::Invalid) { build(info, tenant: tenant) }
    assert_equal reason, error.reason
    assert_kind_of Symbol, error.reason
    error
  end

  test "builds an identity from raw_info" do
    identity = build
    assert_equal OID, identity.oid
    assert_equal TID, identity.tid
    assert_equal "Taro Yamada", identity.name
    assert_equal "taro@example.com", identity.email
    assert_equal "hint-value", identity.login_hint
    assert_equal "subject-value", identity.claims["sub"]
  end

  test "oid and tid are required" do
    [ nil, "", "   ", "\t\n", 123, [ OID ], {} ].each do |bad|
      assert_invalid :missing_claims, raw_info(oid: bad)
      assert_invalid :missing_claims, raw_info(tid: bad)
    end
    info = raw_info
    info.delete("oid")
    assert_invalid :missing_claims, info
    info = raw_info
    info.delete("tid")
    assert_invalid :missing_claims, info
  end

  test "missing raw_info is missing_claims" do
    assert_raises(EntraAuth::VerifiedIdentity::Invalid) do
      EntraAuth::VerifiedIdentity.from_auth_hash(OmniAuth::AuthHash.new(uid: "x"), expected_tenant_id: TID)
    end.then { |e| assert_equal :missing_claims, e.reason }
    assert_invalid :missing_claims, nil
    assert_invalid :missing_claims, "not a hash"
  end

  test "tenant mismatch fails" do
    assert_invalid :tenant_mismatch, raw_info(tid: "99999999-2222-3333-4444-555555555555")
  end

  test "blank expected tenant fails closed" do
    assert_invalid :tenant_mismatch, raw_info, tenant: ""
    assert_invalid :tenant_mismatch, raw_info, tenant: nil
  end

  test "tenant comparison ignores case and surrounding whitespace" do
    identity = build(raw_info(tid: "  #{TID.upcase}  "), tenant: " #{TID} ")
    assert_equal TID, identity.tid
  end

  test "oid and tid are stored trimmed and lowercase" do
    identity = build(raw_info(oid: " #{OID.upcase} ", tid: TID.upcase))
    assert_equal OID, identity.oid
    assert_equal TID, identity.tid
    assert_equal build.oid, identity.oid
  end

  test "email, name and login_hint are optional" do
    info = raw_info
    %w[email name login_hint].each { |k| info.delete(k) }
    identity = build(info)
    assert_nil identity.email
    assert_nil identity.name
    assert_nil identity.login_hint
    assert_equal OID, identity.oid
    assert_equal TID, identity.tid
  end

  test "blank or non-string optional claims become nil" do
    identity = build(raw_info(email: "  ", name: "", login_hint: nil))
    assert_nil identity.email
    assert_nil identity.name
    assert_nil identity.login_hint
    assert_nil build(raw_info(email: 42)).email
  end

  test "different oids in the same tenant are different identities" do
    a = build
    b = build(raw_info(oid: OTHER_OID))
    refute_equal a, b
    refute_equal a.oid, b.oid
    assert_equal a.tid, b.tid
  end

  test "email and name changes do not affect oid and tid" do
    a = build
    b = build(raw_info(email: "changed@example.com", name: "Someone Else"))
    assert_equal [ a.oid, a.tid ], [ b.oid, b.tid ]
    refute_equal a.email, b.email
  end

  test "identity and claims are frozen and deeply read-only" do
    identity = build(raw_info("roles" => [ "Admin" ], "nested" => { "a" => [ { "b" => "c" } ] }))
    assert identity.frozen?
    assert identity.claims.frozen?
    assert identity.claims["roles"].frozen?
    assert identity.claims["roles"].first.frozen?
    assert identity.claims["nested"]["a"].first.frozen?
    assert_raises(FrozenError) { identity.claims["x"] = 1 }
    assert_raises(FrozenError) { identity.claims["roles"] << "Other" }
    assert_raises(FrozenError) { identity.oid << "x" }
  end

  test "claims is a copy, not the caller's raw_info" do
    info = raw_info
    identity = build(info)
    info["oid"] = "mutated"
    assert_equal OID, identity.claims["oid"]
    refute info.frozen?
  end

  test "claims keys are normalized to strings" do
    symbol_info = { oid: OID, tid: TID, email: "a@example.com", nested: { inner: 1 }, list: [ { k: "v" } ] }
    identity = build(symbol_info)
    assert_equal OID, identity.oid
    assert_equal "a@example.com", identity.email
    assert identity.claims.keys.all?(String)
    assert_equal 1, identity.claims["nested"]["inner"]
    assert_equal "v", identity.claims["list"].first["k"]
    assert_nil identity.claims[:oid]
  end

  test "claims of an OmniAuth::AuthHash raw_info are plain string-key hash" do
    identity = build(OmniAuth::AuthHash.new(raw_info))
    assert_instance_of Hash, identity.claims
    assert identity.claims.keys.all?(String)
  end

  test "credentials and raw tokens never appear in the identity" do
    identity = build
    dump = [ identity.to_h.to_s, identity.inspect, identity.claims.to_s ].join(" ")
    [ ACCESS_TOKEN, REFRESH_TOKEN, RAW_ID_TOKEN ].each { |s| refute_includes dump, s }
    refute identity.claims.key?("credentials")
    refute identity.claims.key?("token")
  end

  test "only raw_info is read, never credentials" do
    auth = auth_hash
    auth.credentials.define_singleton_method(:[]) { |*| raise "credentials must not be read" }
    identity = EntraAuth::VerifiedIdentity.from_auth_hash(auth, expected_tenant_id: TID)
    assert_equal OID, identity.oid
  end

  test "Invalid messages carry no claim values" do
    secret_tid = "99999999-SECRET-TENANT"
    e1 = assert_invalid :tenant_mismatch, raw_info(tid: secret_tid, name: "Secret Name")
    e2 = assert_invalid :missing_claims, raw_info(oid: "", name: "Secret Name")
    [ e1, e2 ].each do |e|
      %w[Secret SECRET taro@example.com 99999999 aaaaaaaa].each { |v| refute_includes e.message, v }
      refute_includes e.message, TID
    end
  end

  test "Invalid is a StandardError nested in VerifiedIdentity" do
    assert_operator EntraAuth::VerifiedIdentity::Invalid, :<, StandardError
    assert_equal :missing_claims, EntraAuth::VerifiedIdentity::Invalid.new(:missing_claims).reason
  end
end
