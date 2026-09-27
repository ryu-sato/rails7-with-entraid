module Authorization
  # Reads and validates the role source setting (Settings.authorization.*):
  #
  #   role_source    "roles"  - App Role values from the roles claim
  #                  "groups" - group Object IDs mapped through group_role_map
  #   group_role_map { "<group object id>" => "<role name>" }, groups source only
  #
  # role_source has no default on purpose: leaving it out is a configuration
  # error, not a silent choice. Messages name the setting, never its value.
  module RoleSource
    SOURCES = %w[roles groups].freeze

    class ConfigurationError < StandardError; end

    class << self
      # The configured source ("roles" or "groups"). Raises ConfigurationError
      # when it is unset or unsupported.
      def current(settings = Settings)
        value = settings.authorization&.role_source.to_s
        return value if SOURCES.include?(value)

        raise ConfigurationError,
              "authorization.role_source must be set to one of: #{SOURCES.join(', ')} " \
              "(see config/settings/<env>.yml)"
      end

      # { "<lowercase group object id>" => "<role name>" }
      def group_role_map(settings = Settings)
        raw = settings.authorization&.group_role_map
        return {} if raw.blank?

        raw.to_h.to_h { |guid, role| [ guid.to_s.downcase, role.to_s ] }
      end

      # Boot-time check. Raises for an unset / unsupported source; for the groups
      # source it only warns about a mapping that can never grant a role. Warnings
      # name role names and counts, never group Object IDs.
      def validate!(settings = Settings, logger: Rails.logger)
        return unless current(settings) == "groups"

        map = group_role_map(settings)
        if map.empty?
          logger.warn("[authorization] authorization.group_role_map is empty: " \
                      "no user can receive a role with role_source=groups")
          return
        end

        undefined = map.values.uniq - Role::NAMES
        return if undefined.empty?

        logger.warn("[authorization] authorization.group_role_map refers to undefined roles " \
                    "(ignored at sign-in): #{undefined.join(', ')}")
      end
    end
  end
end
