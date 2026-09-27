require "test_helper"
require "net/http"

class OidcProviderStubTest < ActiveSupport::TestCase
  include OidcProviderStub::Helpers

  setup { install_oidc_provider_stub }

  test "stub issues a valid ID token whose signature verifies with the JWKS" do
    token = oidc_stub.id_token(nonce: "n-123", oid: "oid-1")

    discovery = JSON.parse(Net::HTTP.get(URI("#{oidc_stub.issuer}/.well-known/openid-configuration")))
    assert_equal oidc_stub.issuer, discovery["issuer"]
    %w[authorization_endpoint token_endpoint jwks_uri end_session_endpoint userinfo_endpoint].each do |key|
      assert discovery[key].present?, "discovery should include #{key}"
    end

    jwks = JSON.parse(Net::HTTP.get(URI(discovery["jwks_uri"])))
    claims = JSON::JWT.decode(token, JSON::JWK::Set.new(jwks))

    assert_equal oidc_stub.issuer, claims[:iss]
    assert_equal oidc_stub.client_id, claims[:aud]
    assert_equal "n-123", claims[:nonce]
    assert_equal "oid-1", claims[:oid]
    assert_equal oidc_stub.tenant_id, claims[:tid]
    assert_operator claims[:exp], :>, Time.now.to_i
  end

  test "a token signed with another key does not verify" do
    other = OpenSSL::PKey::RSA.new(2048)
    forged = JSON::JWT.new(oidc_stub.default_claims).sign(other, :RS256)
    forged.header[:kid] = oidc_stub.kid
    jwks = JSON.parse(Net::HTTP.get(URI(oidc_stub.jwks_uri)))
    assert_raises(JSON::JWS::VerificationFailed) { JSON::JWT.decode(forged.to_s, JSON::JWK::Set.new(jwks)) }
  end

  test "token endpoint returns the configured ID token" do
    oidc_stub.token_response_id_token = oidc_stub.id_token(nonce: "abc")
    res = Net::HTTP.post_form(URI(oidc_stub.token_endpoint), "grant_type" => "authorization_code", "code" => "x")
    body = JSON.parse(res.body)
    assert_equal oidc_stub.token_response_id_token, body["id_token"]
    assert_equal "Bearer", body["token_type"]
  end

  test "requests to a non-stubbed host are refused" do
    assert_raises(WebMock::NetConnectNotAllowedError) { Net::HTTP.get(URI("https://example.invalid/anything")) }
    assert_raises(WebMock::NetConnectNotAllowedError) { Net::HTTP.get(URI("https://login.microsoftonline.com/common/v2.0/.well-known/openid-configuration")) }
  end

  test "test env has Entra config defaults and OmniAuth test mode helper works" do
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, ENV["ENTRA_TENANT_ID"])
    assert ENV["ENTRA_CLIENT_ID"].present?
    assert ENV["ENTRA_CLIENT_SECRET"].present?
    assert_equal "http://www.example.com", ENV["ENTRA_APP_BASE_URL"]

    set_omniauth_mock(uid: "oid-9", info: { email: "a@example.com" })
    assert OmniAuth.config.test_mode
    assert_equal "oid-9", OmniAuth.config.mock_auth[:openid_connect].uid
  end

  # Either order works: each test sets a mock, and every test must start clean.
  2.times do |n|
    test "OmniAuth state starts clean and is polluted only within the test (#{n})" do
      assert_not OmniAuth.config.test_mode, "test_mode should be reset by a previous test"
      assert_nil OmniAuth.config.mock_auth[:openid_connect], "mock_auth should be reset by a previous test"
      set_omniauth_mock(uid: "leak-#{n}")
    end
  end
end
