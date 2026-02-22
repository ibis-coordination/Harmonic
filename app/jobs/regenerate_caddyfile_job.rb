# typed: strict
# frozen_string_literal: true

# Regenerates the Caddyfile from tenant subdomains and reloads Caddy.
#
# This job runs outside tenant scope (SystemJob) since it needs to query
# all tenants across the system.
#
# The Caddyfile is written to disk (bind-mounted from host) so it persists
# across Caddy restarts, then Caddy's admin API is called to reload.
class RegenerateCaddyfileJob < SystemJob
  extend T::Sig

  # Caddy admin API endpoint (available on docker network)
  CADDY_ADMIN_URL = T.let(ENV.fetch("CADDY_ADMIN_URL", "http://caddy:2019"), String)

  # Path to write the Caddyfile (bind-mounted from host in both dev and production)
  CADDYFILE_PATH = T.let(ENV.fetch("CADDYFILE_PATH", "/app/Caddyfile"), String)

  sig { void }
  def perform
    Rails.logger.info("[RegenerateCaddyfileJob] Starting Caddyfile regeneration")

    content = CaddyfileGenerator.new.generate

    # Write to disk (persists across restarts)
    File.write(CADDYFILE_PATH, content)
    Rails.logger.info("[RegenerateCaddyfileJob] Wrote Caddyfile to #{CADDYFILE_PATH}")

    # Reload Caddy via admin API
    reload_caddy(content)

    Rails.logger.info("[RegenerateCaddyfileJob] Caddyfile written and Caddy reloaded")
  end

  private

  sig { params(content: String).void }
  def reload_caddy(content)
    uri = URI.parse("#{CADDY_ADMIN_URL}/load")

    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 30
    http.open_timeout = 5

    request = Net::HTTP::Post.new(uri.path)
    request["Content-Type"] = "text/caddyfile"
    request.body = content

    response = http.request(request)

    if response.code.to_i >= 200 && response.code.to_i < 300
      Rails.logger.info("[RegenerateCaddyfileJob] Caddy configuration loaded successfully")
    else
      Rails.logger.error("[RegenerateCaddyfileJob] Caddy reload failed: #{response.code} #{response.body}")
      raise "Caddy reload failed: #{response.code} - #{response.body}"
    end
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Net::OpenTimeout => e
    Rails.logger.warn("[RegenerateCaddyfileJob] Could not connect to Caddy admin API: #{e.message}")
    Rails.logger.warn("[RegenerateCaddyfileJob] Run ./scripts/generate-caddyfile.sh manually if needed")
  end
end
