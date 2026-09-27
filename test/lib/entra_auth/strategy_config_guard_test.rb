require "test_helper"

# Task 2.8: an incomplete configuration (issuer / client identifier / secret /
# redirect_uri blank) fails with fail!(:invalid_configuration) BEFORE any
# discovery (no outbound HTTP at all, not even the gem's WebFinger fallback)
# and without creating any session state (state / nonce / PKCE verifier).
class EntraAuthStrategyConfigGuardTest < ActiveSupport::TestCase
  include StrategyRackHarness

  BLANKS = [ nil, "", "  " ].freeze

  # item => lambda producing the options with that item blanked
  ITEMS = {
    "issuer" => ->(base, v) { base.merge(issuer: v) },
    "identifier" => ->(base, v) { base.merge(client_options: base[:client_options].merge(identifier: v)) },
    "secret" => ->(base, v) { base.merge(client_options: base[:client_options].merge(secret: v)) },
    "redirect_uri" => ->(base, v) { base.merge(client_options: base[:client_options].merge(redirect_uri: v)) }
  }.freeze

  def use_options(options)
    @app = build_app(strategy_class, options)
  end

  def assert_guarded
    assert_equal [ :invalid_configuration ], @fail_keys
    assert_empty @auth_results
    assert_not_requested :any, /.*/
    assert_equal [], WebMock::RequestRegistry.instance.requested_signatures.hash.keys
    stored = @sessions.flat_map(&:keys).grep(/state|nonce|pkce/i)
    assert_empty stored, "no state/nonce/PKCE may be generated"
    visible = [ last_response.body, last_response.headers.to_a.flatten.join(" ") ].join(" ")
    assert_not_includes visible, CLIENT_SECRET
  end

  ITEMS.each do |item, build|
    BLANKS.each do |blank|
      test "request phase with #{item} #{blank.inspect} fails with invalid_configuration and no request" do
        use_options(build.call(strategy_options, blank))
        post "/auth/openid_connect"

        assert_guarded
        assert_not last_response.redirect?
      end

      test "callback phase with #{item} #{blank.inspect} fails with invalid_configuration and no request" do
        use_options(build.call(strategy_options, blank))
        get "/auth/openid_connect/callback", code: "auth-code-1", state: "some-state"

        assert_guarded
      end
    end
  end

  test "a complete configuration is unaffected (request phase redirects to authorize)" do
    post "/auth/openid_connect"

    assert_empty @fail_keys
    assert last_response.redirect?
    assert last_response.headers["location"].start_with?(oidc_stub.authorization_endpoint)
  end
end
