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
    MAX_NONCE_LENGTH = 64

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

      # Use the raw socket peer IP (REMOTE_ADDR), not `request.remote_ip`.
      # `remote_ip` walks the X-Forwarded-For header and Rails trusts private
      # IP ranges by default, which means any peer on the docker network
      # could spoof XFF to impersonate an allowed internal IP. For the
      # internal allowlist we only trust the TCP peer, which can't be
      # spoofed without network-level access.
      peer_ip = request.env["REMOTE_ADDR"].to_s

      unless allowed_ips.any? { |ip| peer_ip == ip || ip_in_cidr?(peer_ip, ip) }
        Rails.logger.warn("[Internal] Blocked request from #{peer_ip} (XFF was: #{request.headers['X-Forwarded-For'].inspect})")
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
      nonce = request.headers["X-Internal-Nonce"]

      if signature.blank? || timestamp.blank? || nonce.blank?
        render json: { error: "Missing signature, timestamp, or nonce" }, status: :unauthorized
        return
      end

      # Bound the nonce size to prevent a hostile caller from eating arbitrary
      # Redis space via the replay cache.
      if nonce.length > MAX_NONCE_LENGTH
        render json: { error: "Invalid nonce" }, status: :unauthorized
        return
      end

      # Strict prefix check — refuse anything that isn't explicitly `sha256=...`.
      # `String#sub` silently leaves the original value intact if the prefix is
      # absent; that's a permissive parse we don't want on an auth check.
      unless signature.start_with?("sha256=")
        Rails.logger.warn("[Internal] Malformed signature header from #{peer_ip}")
        render json: { error: "Invalid signature" }, status: :unauthorized
        return
      end

      # Coarse replay window: requests older than the tolerance are always
      # rejected. Fine-grained replay prevention within the window is done
      # below via the nonce cache.
      request_time = Time.at(timestamp.to_i)
      if (Time.current - request_time).abs > TIMESTAMP_TOLERANCE
        render json: { error: "Request timestamp too old" }, status: :unauthorized
        return
      end

      # `request.raw_post` is the canonical pattern for webhook signature
      # verification: Rails memoizes it and it doesn't consume the underlying
      # rewindable body, so later params parsing still sees the real payload.
      # Reading `request.body` directly races with the params parser and can
      # cause the HMAC check to see "" while the action sees the real body.
      body = request.raw_post
      expected = OpenSSL::HMAC.hexdigest("sha256", secret, "#{nonce}.#{timestamp}.#{body}")
      actual = signature.delete_prefix("sha256=")

      unless ActiveSupport::SecurityUtils.secure_compare(expected, actual)
        Rails.logger.warn("[Internal] Invalid HMAC signature from #{peer_ip}")
        render json: { error: "Invalid signature" }, status: :unauthorized
        return
      end

      # Fine-grained replay protection: once a nonce has been seen within the
      # tolerance window, any further request bearing it is rejected. Uses
      # Redis SETNX so the check-and-insert is atomic across workers.
      if nonce_already_seen?(nonce)
        Rails.logger.warn("[Internal] Replayed nonce from #{peer_ip}: #{nonce}")
        render json: { error: "Replay detected" }, status: :unauthorized
      end
    end

    sig { returns(String) }
    def peer_ip
      request.env["REMOTE_ADDR"].to_s
    end

    # Atomic "have we seen this nonce already?" using Redis SETNX with a TTL
    # equal to the signature tolerance. Returns true if the nonce was already
    # present (i.e. this is a replay).
    sig { params(nonce: String).returns(T::Boolean) }
    def nonce_already_seen?(nonce)
      redis = Redis.new(url: ENV["REDIS_URL"])
      # redis-rb returns `true` when the key was inserted, `false` when the
      # NX condition rejected the SET because the key already existed.
      !redis.set("internal:nonce:#{nonce}", "1", ex: TIMESTAMP_TOLERANCE.to_i, nx: true)
    ensure
      redis&.close
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
