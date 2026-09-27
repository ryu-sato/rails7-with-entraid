require "test_helper"

# Rack harness (session + strategy + terminal app, WebMock OIDC provider) is
# shared via test/support/strategy_rack_harness.rb.
class EntraAuthStrategyTest < ActiveSupport::TestCase
  include StrategyRackHarness

  # ---- request phase ------------------------------------------------------

  test "request phase redirects to the authorization endpoint with state, nonce and S256 PKCE" do
    post "/auth/openid_connect"

    assert_equal 302, last_response.status
    location, params = authorize_params
    assert_equal URI(oidc_stub.authorization_endpoint).path, location.path
    assert_equal "code", params["response_type"]
    assert_equal oidc_stub.client_id, params["client_id"]
    assert_equal REDIRECT_URI, params["redirect_uri"]
    assert_equal %w[email openid profile], params["scope"].split.sort
    assert params["state"].present?
    assert params["nonce"].present?
    assert params["code_challenge"].present?
    assert_equal "S256", params["code_challenge_method"]

    session = @sessions.last
    assert_equal params["state"], session["omniauth.state"]
    assert_equal params["nonce"], session["omniauth.nonce"]
    verifier = session["omniauth.pkce.verifier"]
    assert verifier.present?
    assert_equal Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false), params["code_challenge"]
  end

  test "fixed options are set and caller-supplied ones are not overridden" do
    opts = strategy_class.default_options
    assert_equal "openid_connect", opts.name
    assert_equal true, opts.discovery
    assert_equal :code, opts.response_type
    assert_equal true, opts.pkce
    assert_equal %i[openid profile email], opts.scope
    assert_equal :post, opts.client_auth_method
    assert_equal true, opts.send_state
    assert_equal true, opts.send_nonce
    assert_equal true, opts.require_state
    assert_nil opts.issuer
    assert_nil opts.client_options.identifier
    assert_nil opts.client_options.secret
    assert_nil opts.client_options.redirect_uri
  end

  # ---- callback phase -----------------------------------------------------

  test "callback builds omniauth.auth from the verified ID token (oid, tid, login_hint)" do
    sign_in_with(login_hint: "opaque-login-hint")

    assert_equal 200, last_response.status
    assert_empty @fail_keys
    auth = @auth_results.last
    assert_not_nil auth
    assert_equal "openid_connect", auth.provider
    raw_info = auth.extra.raw_info
    assert_equal "00000000-0000-0000-0000-000000000001", raw_info["oid"]
    assert_equal oidc_stub.tenant_id, raw_info["tid"]
    assert_equal "opaque-login-hint", raw_info["login_hint"]
    assert_equal "Test User", raw_info["name"]
    assert_equal "test.user@example.com", raw_info["email"]
  end

  test "SPIKE (a): raw_info has String keys, so plain string access works without indifferent access" do
    sign_in_with
    raw_info = @auth_results.last.extra.raw_info

    assert_equal "00000000-0000-0000-0000-000000000001", raw_info["oid"]
    assert(raw_info.keys.all? { |k| k.is_a?(String) }, "expected only String keys, got #{raw_info.keys.map(&:class).uniq}")
    assert_kind_of Hash, raw_info
  end

  test "token request carries client credentials in the body (client_auth_method :post) and PKCE code_verifier" do
    params = sign_in_with
    verifier_expected_challenge = params["code_challenge"]

    assert_requested(:post, oidc_stub.token_endpoint, times: 1) do |req|
      form = Rack::Utils.parse_query(req.body)
      req.headers["Authorization"].nil? &&
        form["client_id"] == oidc_stub.client_id &&
        form["client_secret"] == CLIENT_SECRET &&
        form["grant_type"] == "authorization_code" &&
        form["code"] == "auth-code-1" &&
        form["redirect_uri"] == REDIRECT_URI &&
        Base64.urlsafe_encode64(Digest::SHA256.digest(form["code_verifier"].to_s), padding: false) == verifier_expected_challenge
    end
  end

  test "state, nonce and PKCE verifier are consumed from the session after the callback" do
    sign_in_with

    session = @sessions.last
    assert_not session.key?("omniauth.state")
    assert_not session.key?("omniauth.nonce")
    assert_not session.key?("omniauth.pkce.verifier")
  end

  test "SPIKE (b)/(c): sign-in does not call the userinfo endpoint; claims come from the verified ID token" do
    sign_in_with(login_hint: "hint")

    assert_not_requested(:get, oidc_stub.userinfo_endpoint)
    raw_info = @auth_results.last.extra.raw_info
    %w[oid tid name email login_hint].each { |key| assert raw_info.key?(key), "raw_info lacks #{key}" }
    assert_equal "test.user@example.com", @auth_results.last.info.email
    assert_equal "sub-11111111", @auth_results.last.uid
  end

  test "SPIKE (c): an unreachable userinfo endpoint does not affect sign-in" do
    WebMock.stub_request(:get, oidc_stub.userinfo_endpoint).to_timeout
    sign_in_with

    assert_equal 200, last_response.status
    assert_not_nil @auth_results.last
  end

  test "SPIKE (d): discovery and jwks are each fetched during a sign-in round trip (counts recorded)" do
    sign_in_with

    # request phase + callback phase each build a new strategy instance and discover!.
    assert_requested(:get, oidc_stub.discovery_url, times: 2)
    assert_requested(:get, oidc_stub.jwks_uri, times: 1)
  end

  # ---- the stock gem, for the spike record -------------------------------

  test "SPIKE (b): the stock gem strategy DOES call the userinfo endpoint during callback" do
    @app = build_app(OmniAuth::Strategies::OpenIDConnect, strategy_options(discovery: true, response_type: :code, pkce: true, client_auth_method: :post))
    sign_in_with

    assert_requested(:get, oidc_stub.userinfo_endpoint, times: 1)
  end

  test "SPIKE (c): with the stock gem a failing userinfo endpoint is not a clean sign-in (recorded behavior: the gem itself calls fail! with odd keys, no exception; 2.3 normalizes)" do
    stock_options = strategy_options(discovery: true, response_type: :code, pkce: true, client_auth_method: :post)

    WebMock.stub_request(:get, oidc_stub.userinfo_endpoint).to_timeout
    @app = build_app(OmniAuth::Strategies::OpenIDConnect, stock_options)
    sign_in_with
    assert_empty @auth_results, "no auth result may be produced when userinfo times out"
    assert_equal [ :"execution expired" ], @fail_keys

    @fail_keys.clear
    WebMock.stub_request(:get, oidc_stub.userinfo_endpoint).to_return(status: 500, body: "{}")
    @app = build_app(OmniAuth::Strategies::OpenIDConnect, stock_options)
    sign_in_with
    assert_empty @auth_results
    assert_equal [ :"Unknown HttpError" ], @fail_keys
  end
end
