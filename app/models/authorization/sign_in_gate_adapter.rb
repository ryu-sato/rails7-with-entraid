module Authorization
  # Connects entra-authentication's sign-in gate to RoleSync.
  #
  # Registered once at boot (config/initializers/authorization.rb). Authentication
  # calls the gate after it has found or created the user and before it signs
  # anyone in, so a rejection here means the user is never signed in.
  #
  # Contract with EntraAuth::SignInGate: a gate is called with (identity, user)
  # and returns a Decision; it persists its own changes (RoleSync does, on accept
  # and on reject); a rejection's message is shown to the user as it is, so it is
  # always one of the fixed texts under authorization.rejections.
  module SignInGateAdapter
    # -> EntraAuth::SignInGate::Decision
    def self.call(identity, user)
      case (outcome = RoleSync.call(user: user, raw_info: identity.claims))
      when Result::Synced
        EntraAuth::SignInGate.accept
      when Result::Rejected
        EntraAuth::SignInGate.reject(
          reason: outcome.reason,
          message: I18n.t("authorization.rejections.#{outcome.reason}")
        )
      end
    end
  end
end
