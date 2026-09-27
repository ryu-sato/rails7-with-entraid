# Wires up entra-authorization.
#
# This runs after initialization: Authorization::* and Role are app/ constants,
# which are not autoloadable while config/initializers are being loaded.
Rails.application.config.after_initialize do
  # Fail fast when the role source is unset or unsupported, and warn about group
  # mappings that cannot grant a role.
  Authorization::RoleSource.validate!

  # Let entra-authentication ask us whether a verified user may sign in (roles).
  # The constant is looked up on every call, so code reloading in development
  # keeps working.
  EntraAuth::SignInGate.register(->(identity, user) { Authorization::SignInGateAdapter.call(identity, user) })
end
