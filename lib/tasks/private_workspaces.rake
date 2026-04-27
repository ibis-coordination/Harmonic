namespace :private_workspaces do
  desc "Create private workspaces for existing users that don't have one"
  task backfill: :environment do
    created = 0
    skipped = 0
    errors = 0

    User.where(user_type: %w[human ai_agent]).find_each do |user|
      user.tenant_users.each do |tu|
        tenant = tu.tenant
        next unless tenant

        Tenant.scope_thread_to_tenant(subdomain: tenant.subdomain)

        # Check if user already has a private workspace in this tenant
        existing = user.collectives.find_by(collective_type: "private_workspace", tenant_id: tenant.id)
        if existing
          skipped += 1
          next
        end

        begin
          tenant.send(:create_private_workspace_for!, user, tu)
          created += 1
          print "."
        rescue => e
          errors += 1
          puts "\nError creating workspace for #{user.name} (#{user.id}) in #{tenant.subdomain}: #{e.message}"
        ensure
          Collective.clear_thread_scope
        end
      end
    end

    puts "\nDone. Created: #{created}, Skipped: #{skipped}, Errors: #{errors}"
  end

  desc "Enable API on all existing private workspaces"
  task enable_api: :environment do
    updated = 0
    Collective.where(collective_type: "private_workspace").find_each do |workspace|
      unless workspace.feature_enabled?("api")
        workspace.enable_api!
        updated += 1
        print "."
      end
    end
    puts "\nDone. Enabled API on #{updated} workspaces."
  end
end
