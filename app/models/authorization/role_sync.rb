module Authorization
  # Derives a user's roles from the ID token claims at sign-in, applies the rules
  # every method shares, and stores the outcome. This is the only code that
  # writes users.roles.
  #
  # Common rules (identical for both methods, applied here once):
  # - only roles defined in Role::NAMES survive (undefined names are ignored)
  # - no duplicates, in Role::NAMES order
  # - nothing left means the sign-in is refused (:no_roles)
  #
  # On success the stored roles are replaced (not merged). On refusal the stored
  # roles are cleared too, so a session that is still open elsewhere is left with
  # no permissions at all. It never signs anyone in or out and never touches the
  # session: the caller decides from the returned Synced / Rejected.
  #
  # Logs the reason and the user id only, never claim contents.
  module RoleSync
    class << self
      # raw_info: the ID token claims (auth.extra.raw_info; identity.claims in
      # authentication). settings: only tests pass their own.
      # -> Result::Synced | Result::Rejected. Raises RoleSource::ConfigurationError
      # when the role source is unset or unsupported (never guesses a method).
      def call(user:, raw_info:, settings: Settings)
        outcome = resolver_for(settings).call(Claims.from_raw_info(raw_info))
        return reject(user, outcome.reason) if outcome.is_a?(Result::Rejected)

        roles = Role.known(outcome.names)
        return reject(user, :no_roles) if roles.empty?

        user.update!(roles: roles)
        Result::Synced.new(roles: roles)
      end

      private

      def resolver_for(settings)
        case RoleSource.current(settings)
        when "roles" then Resolvers::RolesClaimResolver.new
        when "groups" then Resolvers::GroupsClaimResolver.new(group_role_map: RoleSource.group_role_map(settings))
        end
      end

      def reject(user, reason)
        user.update!(roles: []) if user.persisted?
        Rails.logger.warn("[authorization] login rejected reason=#{reason} user_id=#{user.id || 'none'}")
        Result::Rejected.new(reason: reason)
      end
    end
  end
end
