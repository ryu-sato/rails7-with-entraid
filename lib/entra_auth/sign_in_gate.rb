module EntraAuth
  # Extension point through which downstream code (entra-authorization)
  # decides whether a verified user may sign in.
  #
  # A gate is anything responding to call(identity, user) that returns a
  # Decision (SignInGate.accept / SignInGate.reject). Gates are evaluated in
  # registration order; the first rejection wins. With no gates, sign-in is
  # accepted. This file holds no role / group / permission logic.
  #
  # Contract for gate authors:
  # - Identify people via identity.oid / identity.tid (normalized), never via
  #   identity.claims (raw, not normalized).
  # - A gate may update attributes of user, but persisting them is the GATE's
  #   job (on accept and on reject alike). evaluate neither saves nor rolls
  #   back. Gates must not touch the session.
  # - A rejection's message is shown to end users as-is: do not put raw
  #   claims or identifiers in it.
  # - A gate that raises, or returns something other than a Decision, is
  #   treated as a rejection (reason :gate_error, fixed generic message).
  #
  # user is duck-typed; this library must not reference app classes.
  # Thread-safety: register gates at boot (initializers) only.
  #
  # LOAD-ORDER: no reference to other EntraAuth constants at load time.
  class SignInGate
    # accepted: Boolean, reason: Symbol? (for logs), message: String? (safe to show)
    Decision = Data.define(:accepted, :reason, :message) do
      def accepted? = accepted == true
      def rejected? = !accepted?
    end

    GENERIC_FAILURE_DEFAULT = "サインインに失敗しました。しばらくしてからもう一度お試しください。".freeze
    private_constant :GENERIC_FAILURE_DEFAULT

    @gates = []

    class << self
      def accept
        Decision.new(accepted: true, reason: nil, message: nil)
      end

      def reject(reason:, message:)
        Decision.new(accepted: false, reason: reason, message: message)
      end

      # gate: any object responding to call(identity, user).
      def register(gate)
        raise ArgumentError, "gate must respond to call(identity, user)" unless gate.respond_to?(:call)

        @gates << gate
        nil
      end

      # Never raises. Returns the first rejection, or accept.
      def evaluate(identity, user)
        @gates.each do |gate|
          decision = run_gate(gate, identity, user)
          return with_message(decision) if decision.rejected?
        end
        accept
      rescue StandardError => e
        # Defensive: evaluate itself must never raise (fail closed).
        log_gate_error(e.class.name)
        gate_error
      end

      # For tests: clears all registered gates.
      def reset!
        @gates = []
        nil
      end

      private

      def run_gate(gate, identity, user)
        decision = gate.call(identity, user)
        return decision if decision.is_a?(Decision)

        log_gate_error("non-Decision return")
        gate_error
      rescue StandardError => e
        log_gate_error(e.class.name)
        gate_error
      end

      def gate_error
        reject(reason: :gate_error, message: generic_message)
      end

      # A rejection with a blank message falls back to the generic message.
      def with_message(decision)
        return decision if decision.message.to_s.strip != ""

        decision.with(message: generic_message)
      end

      def generic_message
        I18n.t("entra_authentication.failures.generic", default: GENERIC_FAILURE_DEFAULT)
      end

      # Logs the exception class name and the reason only: never the exception
      # message, identity or claims.
      def log_gate_error(kind)
        Rails.logger.error("[EntraAuth::SignInGate] reason=gate_error cause=#{kind}")
      end
    end
  end
end
