namespace :trio do
  desc "Ensure every tenant has a Trio system agent; refresh identity_prompt on existing ones"
  task reseed: :environment do
    seeded = 0
    refreshed = 0
    skipped = 0
    errors = 0

    Tenant.find_each do |tenant|
      unless tenant.main_collective_id
        skipped += 1
        next
      end

      pre_count = User.where(system_role: "trio").joins(:tenant_users)
        .where(tenant_users: { tenant_id: tenant.id })
        .count

      TrioSeeder.ensure_for(tenant.main_collective)

      if pre_count.zero?
        seeded += 1
        print "+"
      else
        refreshed += 1
        print "."
      end
    rescue => e
      errors += 1
      puts "\nError seeding trio for #{tenant.subdomain}: #{e.message}"
    end

    puts "\n\nTrio reseed complete."
    puts "  Seeded (new):    #{seeded}"
    puts "  Refreshed:       #{refreshed}"
    puts "  Skipped (no main collective): #{skipped}"
    puts "  Errors:          #{errors}"
  end
end
