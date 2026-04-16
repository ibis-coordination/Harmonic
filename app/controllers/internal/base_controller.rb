# typed: true
# frozen_string_literal: true

# Base controller for internal service-to-service APIs.
#
# Security model (different from ApplicationController):
#   1. IP restriction — only requests from INTERNAL_ALLOWED_IPS
#   2. HMAC-SHA256 signature verification — shared secret, never sent over the wire
#   3. Tenant scoping from subdomain — same as external, for data isolation
#   4. No user authentication — the caller is a trusted service, not a user
#   5. No collective scoping — internal services operate at the tenant level
#
# Inherits from ActionController::Base (not ApplicationController) to avoid
# user auth, collective resolution, CSRF, and other user-facing concerns.
module Internal
  class BaseController < ActionController::Base
    extend T::Sig

    skip_forgery_protection

    before_action :verify_ip_restriction
    before_action :verify_hmac_signature
    before_action :resolve_tenant_from_subdomain

    TIMESTAMP_TOLERANCE = 5.minutes

    private

    # Resolve tenant from the request subdomain and set thread-local context.
    # Uses the same Tenant.scope_thread_to_tenant that ApplicationController uses
    # (via Collective.scope_thread_to_collective), so tenant isolation is consistent.
    sig { void }
    def resolve_tenant_from_subdomain
      subdomain = request.subdomain
      if subdomain.blank?
        render json: { error: "Missing subdomain" }, status: :bad_request
        return
      end

      begin
        @current_tenant = Tenant.scope_thread_to_tenant(subdomain: subdomain)
      rescue RuntimeError => e
        Rails.logger.warn("[Internal::BaseController] Tenant resolution failed: #{e.message}")
        render json: { error: "Invalid subdomain" }, status: :not_found
      end
    end

    sig { void }
    def verify_ip_restriction
      allowed_ips = ENV.fetch("INTERNAL_ALLOWED_IPS", "").split(",").map(&:strip)
      # In development/test, allow all if not configured
      return if allowed_ips.empty? && (Rails.env.development? || Rails.env.test?)

      unless allowed_ips.any? { |ip| request.remote_ip == ip || ip_in_cidr?(request.remote_ip, ip) }
        Rails.logger.warn("[Internal] Blocked request from #{request.remote_ip}")
        render json: { error: "Forbidden" }, status: :forbidden
      end
    end

    sig { void }
    def verify_hmac_signature
      secret = ENV["AGENT_RUNNER_SECRET"]
      return if secret.blank? && Rails.env.test?

      if secret.blank?
        render json: { error: "Server misconfigured: AGENT_RUNNER_SECRET not set" }, status: :internal_server_error
        return
      end

      signature = request.headers["X-Internal-Signature"]
      timestamp = request.headers["X-Internal-Timestamp"]

      if signature.blank? || timestamp.blank?
        render json: { error: "Missing signature or timestamp" }, status: :unauthorized
        return
      end

      # Replay protection
      request_time = Time.at(timestamp.to_i)
      if (Time.current - request_time).abs > TIMESTAMP_TOLERANCE
        render json: { error: "Request timestamp too old" }, status: :unauthorized
        return
      end

      # request.body is nil for GET requests under Rack 3; fall back to empty string.
      body = request.body&.read || ""
      request.body&.rewind
      expected = OpenSSL::HMAC.hexdigest("sha256", secret, "#{timestamp}.#{body}")
      actual = signature.sub(/^sha256=/, "")

      unless ActiveSupport::SecurityUtils.secure_compare(expected, actual)
        Rails.logger.warn("[Internal] Invalid HMAC signature from #{request.remote_ip}")
        render json: { error: "Invalid signature" }, status: :unauthorized
      end
    end

    sig { params(ip: String, cidr: String).returns(T::Boolean) }
    def ip_in_cidr?(ip, cidr)
      return false unless cidr.include?("/")

      IPAddr.new(cidr).include?(IPAddr.new(ip))
    rescue IPAddr::InvalidAddressError
      false
    end
  end
end
