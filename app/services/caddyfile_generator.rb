# typed: strict
# frozen_string_literal: true

# Generates Caddyfile content from tenant subdomains in the database.
#
# Used by:
# - RegenerateCaddyfileJob (automatic, on tenant changes)
# - caddyfile:generate rake task (manual, via generate-caddyfile.sh)
class CaddyfileGenerator
  extend T::Sig

  VALID_SUBDOMAIN_PATTERN = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/

  sig { returns(String) }
  def generate
    hostname = ENV.fetch("HOSTNAME")
    primary_subdomain = ENV.fetch("PRIMARY_SUBDOMAIN")
    auth_subdomain = ENV.fetch("AUTH_SUBDOMAIN")

    tenant_subdomains = Tenant.unscoped_for_system_job.pluck(:subdomain)

    lines = []

    # Header
    lines << "# Auto-generated Caddyfile"
    lines << "# Generated at: #{Time.current.iso8601}"
    lines << "# Tenants: #{tenant_subdomains.size}"
    lines << ""

    # Global options
    lines << "{"
    lines << "\tadmin 0.0.0.0:2019"
    lines << "}"
    lines << ""

    # Bare domain redirect
    lines << "#{hostname} {"
    lines << "\tredir https://#{primary_subdomain}.#{hostname}{uri} permanent"
    lines << "}"

    # Primary subdomain
    lines << "#{primary_subdomain}.#{hostname} {"
    lines << "\treverse_proxy web:3000"
    lines << "}"

    # Auth subdomain
    lines << "#{auth_subdomain}.#{hostname} {"
    lines << "\treverse_proxy web:3000"
    lines << "}"

    # Tenant subdomains (excluding primary and auth which are already listed)
    special_subdomains = [primary_subdomain, auth_subdomain].map(&:downcase)

    tenant_subdomains.each do |subdomain|
      next if special_subdomains.include?(subdomain.downcase)
      unless valid_subdomain?(subdomain)
        Rails.logger.warn("[CaddyfileGenerator] Skipping invalid subdomain: #{subdomain}")
        next
      end

      lines << "#{subdomain}.#{hostname} {"
      lines << "\treverse_proxy web:3000"
      lines << "}"
    end

    lines.join("\n") + "\n"
  end

  sig { params(subdomain: String).returns(T::Boolean) }
  def valid_subdomain?(subdomain)
    subdomain.match?(VALID_SUBDOMAIN_PATTERN)
  end
end
