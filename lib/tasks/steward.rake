# typed: false
# frozen_string_literal: true

# Steward agent lifecycle. See docs/STEWARD_AGENTS.md for the identity model
# and StewardProvisioner for the behavior. All three tasks operate on the
# primary tenant and print nothing secret except the one-time token value,
# which is shown exactly once and must be copied straight into the operator's
# credentials file.

namespace :steward do
  def with_primary_tenant
    subdomain = ENV.fetch("PRIMARY_SUBDOMAIN") { abort "steward: PRIMARY_SUBDOMAIN is not set" }
    Tenant.scope_thread_to_tenant(subdomain: subdomain)
    yield Tenant.find_by!(subdomain: subdomain)
  ensure
    Tenant.clear_thread_scope
  end

  def print_token_once(token)
    puts
    puts "Token (shown once — copy into the credentials file, do not log):"
    puts token.plaintext_token
    puts
    puts "Expires: #{token.expires_at}"
  end

  desc "Create a steward agent and mint its read token. Usage: steward:provision[principal_handle] or [principal_handle,handle]"
  task :provision, [:principal_handle, :handle] => :environment do |_t, args|
    abort "steward:provision requires a principal handle, e.g. rake 'steward:provision[your-handle]'" if args[:principal_handle].blank?
    handle = args[:handle].presence || "steward"

    with_primary_tenant do |tenant|
      result = StewardProvisioner.provision!(tenant: tenant, principal_handle: args[:principal_handle], handle: handle)
      puts "Created steward #{result.steward.name.inspect} (handle: #{handle}, sys_admin role granted)"
      print_token_once(result.token)
    rescue StewardProvisioner::PreconditionFailed => e
      abort "steward: #{e.message}"
    end
  end

  desc "Mint a new read token for a steward and revoke its previous ones. Usage: steward:rotate or steward:rotate[handle]"
  task :rotate, [:handle] => :environment do |_t, args|
    handle = args[:handle].presence || "steward"

    with_primary_tenant do |tenant|
      token = StewardProvisioner.rotate!(tenant: tenant, handle: handle)
      puts "Rotated token for steward #{handle.inspect}; previous tokens revoked."
      print_token_once(token)
    rescue StewardProvisioner::PreconditionFailed => e
      abort "steward: #{e.message}"
    end
  end

  desc "Join a steward to its reporting collective and mint a content token (no admin flag). Usage: steward:enable_reporting[collective-handle] or [collective-handle,handle]"
  task :enable_reporting, [:collective_handle, :handle] => :environment do |_t, args|
    abort "steward:enable_reporting requires a collective handle, e.g. rake 'steward:enable_reporting[ops]'" if args[:collective_handle].blank?
    handle = args[:handle].presence || "steward"

    with_primary_tenant do |tenant|
      token = StewardProvisioner.enable_reporting!(tenant: tenant, handle: handle, collective_handle: args[:collective_handle])
      puts "Steward #{handle.inspect} joined collective #{args[:collective_handle].inspect}; content token minted (no admin flag)."
      print_token_once(token)
    rescue StewardProvisioner::PreconditionFailed => e
      abort "steward: #{e.message}"
    end
  end

  desc "Revoke a steward's tokens and remove its sys_admin role. Usage: steward:revoke or steward:revoke[handle]"
  task :revoke, [:handle] => :environment do |_t, args|
    handle = args[:handle].presence || "steward"

    with_primary_tenant do |tenant|
      StewardProvisioner.revoke!(tenant: tenant, handle: handle)
      puts "Revoked all rest tokens and removed sys_admin from steward #{handle.inspect}. The user record remains for attribution history."
    rescue StewardProvisioner::PreconditionFailed => e
      abort "steward: #{e.message}"
    end
  end
end
