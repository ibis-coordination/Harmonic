# Validates ANON_READABLE_TENANT_SUBDOMAINS at boot: any listed subdomain that
# doesn't match an actual Tenant gets a warning in the logs. Silent if the env
# var is unset or every listed subdomain resolves. Never raises — a misconfig
# should not block boot.
Rails.application.config.after_initialize do
  next unless ActiveRecord::Base.connection.data_source_exists?("tenants")

  Tenant.warn_unknown_anon_readable_subdomains!(logger: Rails.logger)
rescue ActiveRecord::ActiveRecordError, PG::Error => e
  Rails.logger.warn(
    "Could not validate ANON_READABLE_TENANT_SUBDOMAINS at boot: #{e.class}: #{e.message}"
  )
end
