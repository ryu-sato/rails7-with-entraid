module EntraAuth
  # Raised by Config.validate!. The message lists item names only.
  class ConfigurationError < StandardError; end

  # Connection settings for Entra ID and session lifetime settings.
  #
  # Each value is read on every call (no memoization) from ENV first, then
  # from Rails.application.credentials.entra_id. Blank values count as unset.
  # Nothing here raises for missing or invalid settings except validate!;
  # derived values return nil while their inputs are unusable.
  #
  # credentials.entra_id keys: tenant_id, client_id, client_secret,
  # app_base_url, idle_minutes, absolute_hours.
  #
  # This is a stateless class: it holds no secret in instance state, so
  # inspect / to_s can never expose client_secret.
  class Config
    ENV_KEYS = {
      tenant_id: "ENTRA_TENANT_ID",
      client_id: "ENTRA_CLIENT_ID",
      client_secret: "ENTRA_CLIENT_SECRET",
      app_base_url: "ENTRA_APP_BASE_URL",
      idle_minutes: "ENTRA_SESSION_IDLE_MINUTES",
      absolute_hours: "ENTRA_SESSION_ABSOLUTE_HOURS"
    }.freeze

    DEFAULT_IDLE_MINUTES = 30
    DEFAULT_ABSOLUTE_HOURS = 8
    GUID_PATTERN = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    POSITIVE_INTEGER = /\A[1-9]\d*\z/

    class << self
      def tenant_id = fetch(:tenant_id)
      def client_id = fetch(:client_id)
      def client_secret = fetch(:client_secret)
      def app_base_url = fetch(:app_base_url)

      # Defaults to 30 minutes. An invalid setting yields the default here so
      # that boot never fails, but it is reported by problems (not hidden).
      def idle_timeout
        (positive_integer(:idle_minutes) || DEFAULT_IDLE_MINUTES).minutes
      end

      # Defaults to 8 hours. Invalid settings behave as for idle_timeout.
      def absolute_timeout
        (positive_integer(:absolute_hours) || DEFAULT_ABSOLUTE_HOURS).hours
      end

      # nil unless tenant_id is a valid GUID.
      def issuer
        "https://login.microsoftonline.com/#{tenant_id}/v2.0" if valid_tenant_id?
      end

      # nil unless app_base_url is a valid http(s) URL.
      def redirect_uri
        base = normalized_base_url
        "#{base}/users/auth/openid_connect/callback" if base
      end

      # nil unless app_base_url is a valid http(s) URL.
      def post_logout_redirect_uri
        base = normalized_base_url
        "#{base}/signed_out" if base
      end

      # Names of missing or invalid items (Symbols). Never contains values.
      def problems
        list = []
        list << :tenant_id unless valid_tenant_id?
        list << :client_id if fetch(:client_id).nil?
        list << :client_secret if fetch(:client_secret).nil?
        list << :app_base_url unless normalized_base_url
        list << :idle_timeout if invalid_positive_integer?(:idle_minutes)
        list << :absolute_timeout if invalid_positive_integer?(:absolute_hours)
        list
      end

      def valid? = problems.empty?

      def validate!
        items = problems
        return if items.empty?

        raise ConfigurationError, "Invalid Entra ID configuration: #{items.join(', ')}"
      end

      private

      def fetch(key)
        value = ENV[ENV_KEYS.fetch(key)]
        value = credential(key) if value.nil? || value.to_s.strip.empty?
        value = value.to_s.strip
        value.empty? ? nil : value
      end

      def credential(key)
        section = Rails.application.credentials.entra_id
        section.respond_to?(:[]) ? section[key] : nil
      end

      def valid_tenant_id?
        GUID_PATTERN.match?(tenant_id.to_s)
      end

      # Integer > 0 as a String of digits (from ENV or credentials), else nil.
      def positive_integer(key)
        raw = fetch(key)
        raw&.match?(POSITIVE_INTEGER) ? raw.to_i : nil
      end

      def invalid_positive_integer?(key)
        !fetch(key).nil? && positive_integer(key).nil?
      end

      def normalized_base_url
        raw = app_base_url
        return nil unless raw

        uri = URI.parse(raw)
        return nil unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.query.nil? && uri.fragment.nil?

        raw.chomp("/")
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
