require "json/jwt"
require "openssl"
require "securerandom"
require "webmock/minitest"

# Local, fake OIDC provider for tests (Entra ID v2.0 single-tenant shape).
# Nothing here talks to a real server: it only signs tokens with a throwaway
# RSA key and registers WebMock stubs for the issuer's URLs.
class OidcProviderStub
  FAKE_TENANT_ID = "11111111-2222-3333-4444-555555555555".freeze
  FAKE_CLIENT_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".freeze
  FAKE_CLIENT_SECRET = "test-client-secret".freeze
  FAKE_APP_BASE_URL = "http://www.example.com".freeze

  KID = "test-key-1".freeze

  # Generated once per process and shared (2048-bit generation is slow).
  def self.rsa_key
    @rsa_key ||= OpenSSL::PKey::RSA.generate(2048)
  end

  attr_reader :tenant_id, :client_id
  attr_accessor :token_response_id_token, :userinfo_claims

  def initialize(tenant_id: ENV.fetch("ENTRA_TENANT_ID", FAKE_TENANT_ID),
                 client_id: ENV.fetch("ENTRA_CLIENT_ID", FAKE_CLIENT_ID))
    @tenant_id = tenant_id
    @client_id = client_id
  end

  def kid = KID
  def rsa_key = self.class.rsa_key
  def issuer = "https://login.microsoftonline.com/#{tenant_id}/v2.0"
  def discovery_url = "#{issuer}/.well-known/openid-configuration"
  def jwks_uri = "https://login.microsoftonline.com/#{tenant_id}/discovery/v2.0/keys"
  def authorization_endpoint = "https://login.microsoftonline.com/#{tenant_id}/oauth2/v2.0/authorize"
  def token_endpoint = "https://login.microsoftonline.com/#{tenant_id}/oauth2/v2.0/token"
  def end_session_endpoint = "https://login.microsoftonline.com/#{tenant_id}/oauth2/v2.0/logout"
  def userinfo_endpoint = "https://graph.microsoft.com/oidc/userinfo"

  def jwks
    jwk = JSON::JWK.new(rsa_key.public_key, kid: kid, use: "sig", alg: "RS256")
    { keys: [ jwk ] }
  end

  def discovery_document
    {
      issuer: issuer,
      authorization_endpoint: authorization_endpoint,
      token_endpoint: token_endpoint,
      jwks_uri: jwks_uri,
      end_session_endpoint: end_session_endpoint,
      userinfo_endpoint: userinfo_endpoint,
      response_types_supported: %w[code id_token],
      subject_types_supported: %w[pairwise],
      id_token_signing_alg_values_supported: %w[RS256],
      scopes_supported: %w[openid profile email offline_access]
    }
  end

  def default_claims(now: Time.now.to_i)
    {
      iss: issuer,
      aud: client_id,
      iat: now,
      nbf: now,
      exp: now + 3600,
      sub: "sub-#{tenant_id[0, 8]}",
      tid: tenant_id,
      oid: "00000000-0000-0000-0000-000000000001",
      name: "Test User",
      email: "test.user@example.com",
      preferred_username: "test.user@example.com",
      nonce: "test-nonce"
    }
  end

  # Signs an RS256 ID token. Overrides are merged over the defaults; pass
  # `key: nil` in overrides to drop a claim (e.g. `nonce: nil`).
  def id_token(**overrides)
    claims = default_claims.merge(overrides).compact
    jwt = JSON::JWT.new(claims)
    jwt.kid = kid
    jwt.sign(rsa_key, :RS256).to_s
  end

  # Registers the WebMock stubs (discovery, jwks, token, userinfo).
  def install!
    json = { "Content-Type" => "application/json" }
    WebMock.stub_request(:get, discovery_url)
           .to_return { |_| { status: 200, headers: json, body: discovery_document.to_json } }
    WebMock.stub_request(:get, jwks_uri)
           .to_return { |_| { status: 200, headers: json, body: jwks.to_json } }
    WebMock.stub_request(:post, token_endpoint)
           .to_return do |_|
             body = { token_type: "Bearer", access_token: "test-access-token", expires_in: 3600 }
             body[:id_token] = token_response_id_token if token_response_id_token
             { status: 200, headers: json, body: body.to_json }
           end
    WebMock.stub_request(:get, userinfo_endpoint)
           .to_return { |_| { status: 200, headers: json, body: (userinfo_claims || { sub: default_claims[:sub] }).to_json } }
    self
  end

  # Include in test cases: `install_oidc_provider_stub` in setup, then `oidc_stub`.
  module Helpers
    def oidc_stub
      @oidc_stub ||= OidcProviderStub.new
    end

    def install_oidc_provider_stub
      oidc_stub.install!
    end

    # Sets OmniAuth test mode with a mock :openid_connect auth hash.
    def set_omniauth_mock(uid: "00000000-0000-0000-0000-000000000001", info: {}, extra: {}, provider: :openid_connect)
      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[provider.to_sym] = OmniAuth::AuthHash.new(
        provider: provider.to_s, uid: uid, info: info, extra: extra
      )
    end

    def after_teardown
      super
      OmniAuth.config.mock_auth.clear
      OmniAuth.config.mock_auth[:default] = OmniAuth::AuthHash.new(provider: "default", uid: "1234")
      OmniAuth.config.test_mode = false
    end
  end
end
