ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
# Entra ID settings for the test env. Values already set in ENV are kept, so
# the suite boots with no ENTRA_* configured. Fake GUID: never a real tenant.
{
  "ENTRA_TENANT_ID" => "11111111-2222-3333-4444-555555555555",
  "ENTRA_CLIENT_ID" => "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
  "ENTRA_CLIENT_SECRET" => "test-client-secret",
  "ENTRA_APP_BASE_URL" => "http://www.example.com"
}.each { |key, value| ENV[key] = value if ENV[key].to_s.empty? }

require "rails/test_help"
require "webmock/minitest"

# No real communication with Entra ID or any external host from tests.
WebMock.disable_net_connect!

Dir[Rails.root.join("test/support/**/*.rb")].sort.each do |file|
  require file unless file.end_with?("_test.rb")
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
    include OidcProviderStub::Helpers

    # Gate registrations are global state: never let them leak between tests.
    setup { EntraAuth::SignInGate.reset! }
    teardown { EntraAuth::SignInGate.reset! }
  end
end

# Devise / Warden helpers (sign_in, login_as, logout) for sign-in integration tests.
class ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
end
