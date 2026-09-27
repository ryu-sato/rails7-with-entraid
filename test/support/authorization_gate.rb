# The gate registered at boot by config/initializers/authorization.rb.
#
# The suite resets EntraAuth::SignInGate around every test (test_helper), which
# also drops the gate registered at boot. The boot registration is captured here,
# when the support files load (after the app booted, before any test runs), so
# tests can put the real thing back instead of re-implementing it.
module AuthorizationGate
  BOOT_GATES = EntraAuth::SignInGate.instance_variable_get(:@gates).dup.freeze

  # Registers exactly what the app registers at boot.
  def register_authorization_gate
    BOOT_GATES.each { |gate| EntraAuth::SignInGate.register(gate) }
  end

  # Temporarily runs with another role source (and group map) in Settings.
  def with_role_source(source, group_role_map = {})
    authorization = Settings.authorization
    saved = [ authorization.role_source, authorization.group_role_map ]
    authorization.role_source = source
    authorization.group_role_map = group_role_map
    yield
  ensure
    authorization.role_source, authorization.group_role_map = saved
  end
end
