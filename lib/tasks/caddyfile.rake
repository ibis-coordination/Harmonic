# typed: false

namespace :caddyfile do
  desc "Generate Caddyfile from tenant subdomains in database"
  task generate: :environment do
    output_path = ENV.fetch("CADDYFILE_OUTPUT", "Caddyfile.generated")

    content = CaddyfileGenerator.new.generate
    File.write(output_path, content)

    tenant_subdomains = Tenant.unscoped_for_system_job.pluck(:subdomain)
    puts "Generated #{output_path} with #{tenant_subdomains.size} tenant(s)"
    puts "Subdomains: #{tenant_subdomains.join(', ')}"
  end

  desc "List tenant subdomains (for shell scripts)"
  task list_subdomains: :environment do
    tenant_subdomains = Tenant.unscoped_for_system_job.pluck(:subdomain)
    puts tenant_subdomains.join("\n")
  end
end
