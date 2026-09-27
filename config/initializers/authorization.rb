# Wires up entra-authorization.

# Fail fast when the role source is unset or unsupported, and warn about group
# mappings that cannot grant a role. This must run after initialization:
# Authorization::* and Role are app/ constants, which are not autoloadable while
# config/initializers are being loaded.
Rails.application.config.after_initialize do
  Authorization::RoleSource.validate!
end
