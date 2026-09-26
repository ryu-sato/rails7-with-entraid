module EntraAuth
  # Expires a session a fixed time after sign-in, regardless of activity.
  #
  # Registered once on Warden's after_set_user hook (see install!):
  # - :authentication (sign-in) and :set_user (test login helpers such as
  #   Devise's sign_in) record warden.session(scope)["login_at"] = now (UNIX
  #   seconds). Every re-sign-in overwrites it, which restarts the clock.
  # - :fetch (restoring an existing session) is the only event that can expire
  #   a session: a missing login_at, or now - login_at > absolute_timeout,
  #   logs the scope out and throws :warden with message :absolute_timeout.
  #   Being exactly at the limit is still valid (strictly greater expires).
  #   :fetch never writes login_at, so activity does not extend the limit.
  # - Any other event does nothing.
  #
  # LOAD ORDER: this file is required before config.rb, so it must not
  # reference other EntraAuth constants at load time. Config is only used
  # inside methods.
  module AbsoluteTimeout
    RECORD_EVENTS = %i[authentication set_user].freeze
    FETCH_EVENT = :fetch
    SESSION_KEY = "login_at".freeze
    MESSAGE = :absolute_timeout

    # The exact object registered with Warden, so install! can detect it.
    HOOK = lambda do |record, warden, opts|
      AbsoluteTimeout.call(record, warden, opts)
    end

    class << self
      # Registers the hook with Warden::Manager exactly once (idempotent).
      def install!
        return false if installed?

        Warden::Manager.after_set_user(&HOOK)
        true
      end

      def installed?
        Warden::Manager._after_set_user.any? { |callback, _conditions| callback.equal?(HOOK) }
      end

      # Hook body. opts is the Warden set_user options (:event, :scope).
      def call(_record, warden, opts)
        scope = opts[:scope]
        case opts[:event]
        when *RECORD_EVENTS
          warden.session(scope)[SESSION_KEY] = Time.now.to_i
        when FETCH_EVENT
          expire!(warden, scope) if expired?(warden.session(scope)[SESSION_KEY])
        end
        nil
      end

      private

      def expired?(login_at)
        return true if login_at.nil?

        Time.now.to_i - login_at.to_i > EntraAuth::Config.absolute_timeout.to_i
      end

      def expire!(warden, scope)
        warden.logout(scope)
        throw :warden, scope: scope, message: MESSAGE
      end
    end
  end
end
