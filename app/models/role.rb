# The single definition of the roles this application recognizes.
#
# Role names live in code, not in the database. Each name must match, exactly,
# the App Role value configured in Entra ID (roles claim method) and the role
# names used in Settings.authorization.group_role_map (groups claim method).
#
# The names below are provisional; the first domain feature fixes them.
module Role
  NAMES = %w[admin member].freeze

  # Narrows +names+ to defined roles: undefined names and non-strings are
  # dropped, duplicates removed, and the result follows the NAMES order.
  # This is the only place these rules are implemented.
  def self.known(names)
    return [] unless names.is_a?(Array)

    NAMES & names.grep(String)
  end
end
