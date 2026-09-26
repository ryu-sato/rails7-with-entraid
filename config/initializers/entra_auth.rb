# Loads the Entra ID authentication library (lib/entra_auth.rb) and wires it up.
require "entra_auth"

# Expire sessions a fixed time after sign-in. Idempotent: registered once.
EntraAuth::AbsoluteTimeout.install!

# Fail fast at boot when a production app is misconfigured. The error names
# the items only, never their values. Skipped for asset precompile / Docker
# builds (SECRET_KEY_BASE_DUMMY) and never done in development or test.
if Rails.env.production? && ENV["SECRET_KEY_BASE_DUMMY"].blank?
  EntraAuth::Config.validate!
end
