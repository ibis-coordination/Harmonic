# typed: true

class ApplicationRecord < ActiveRecord::Base
  extend T::Sig
  include SingleTenantMode

  primary_abstract_class

  before_validation :set_tenant_id
  before_validation :set_collective_id
  before_validation :set_updated_by

  default_scope do
    if belongs_to_tenant? && Tenant.current_id
      s = where(tenant_id: Tenant.current_id)
      if belongs_to_collective? && Collective.current_id
        s = s.where(collective_id: Collective.current_id)
      end
      s
    else
      all
    end
  end

  sig { returns(T::Boolean) }
  def self.belongs_to_tenant?
    self.column_names.include?("tenant_id")
  end

  sig { void }
  def set_tenant_id
    if self.class.belongs_to_tenant?
      T.unsafe(self).tenant_id ||= Tenant.current_id
    end
  end

  sig { returns(T::Boolean) }
  def self.belongs_to_collective?
    return false if self == CollectiveMember # This is a special case
    self.column_names.include?("collective_id")
  end

  # Query with only tenant scoping (bypasses collective scope).
  # Use this instead of `unscoped` when you need cross-collective access within a tenant.
  # In request context, tenant_id defaults to Tenant.current_id.
  # In background jobs, pass tenant_id explicitly.
  sig { params(tenant_id: T.nilable(String)).returns(T.untyped) }
  def self.tenant_scoped_only(tenant_id = Tenant.current_id)
    raise ArgumentError, "tenant_id is required for tenant_scoped_only" if tenant_id.nil?
    unscoped.where(tenant_id: tenant_id) # unscoped-allowed - this is the safe wrapper
  end

  # Query without any scoping, for app admin operations.
  # Only callable by app admins or system admins.
  # Use this for cross-tenant admin operations like user management.
  sig { params(current_user: User).returns(T.untyped) }
  def self.unscoped_for_admin(current_user)
    unless current_user.app_admin? || current_user.sys_admin?
      raise ArgumentError, "unscoped_for_admin requires an app_admin or system_admin user"
    end
    unscoped # unscoped-allowed - admin-only cross-tenant access
  end

  # Query without any scoping, for system background jobs.
  # Only callable when no tenant context is set (i.e., in a background job).
  # Use this for maintenance jobs like cleanup and backfills.
  sig { returns(T.untyped) }
  def self.unscoped_for_system_job
    unless Tenant.current_id.nil?
      raise ArgumentError, "unscoped_for_system_job can only be called outside of tenant context"
    end
    unscoped # unscoped-allowed - system job cross-tenant access
  end

  # Query a user's own records across all tenants.
  # Safe because it's constrained to the user's own data.
  # Use this for cross-tenant queries of user's own memberships, tokens, etc.
  sig { params(user: User).returns(T.untyped) }
  def self.for_user_across_tenants(user)
    raise ArgumentError, "#{name} does not have user_id column" unless column_names.include?("user_id")
    unscoped.where(user_id: user.id) # unscoped-allowed - user's own data across tenants
  end

  sig { void }
  def set_collective_id
    if self.class.belongs_to_collective?
      T.unsafe(self).collective_id ||= Collective.current_id
    end
  end

  sig { returns(T::Boolean) }
  def self.is_tracked?
    false
  end

  sig { returns(T::Boolean) }
  def is_tracked?
    self.class.is_tracked?
  end

  sig { void }
  def set_updated_by
    if self.class.column_names.include?("updated_by_id")
      T.unsafe(self).updated_by_id ||= T.unsafe(self).created_by_id
    end
  end

  sig { returns(String) }
  def deadline_iso8601
    if T.unsafe(self).deadline
      T.unsafe(self).deadline.iso8601
    else
      ""
    end
  end

  sig { returns(T::Boolean) }
  def closed?
    T.unsafe(self).deadline && T.unsafe(self).deadline < Time.now
  end

  sig { params(user: User).returns(T::Boolean) }
  def user_can_close?(user)
    user.id == T.unsafe(self).created_by.id
  end

  sig { returns(T::Boolean) }
  def requires_manual_close?
    # Deadline decades in the future represents intention to manually close in the future
    (T.unsafe(self).deadline - Time.current) > 50.years
  end

  sig { returns(T.nilable(String)) }
  def path
    "#{T.unsafe(self).collective.path}/#{T.unsafe(self).path_prefix}/#{T.unsafe(self).truncated_id}"
  end

  sig { returns(T.nilable(String)) }
  def shareable_link
    subdomain = T.unsafe(self).tenant.subdomain
    domain = ENV['HOSTNAME']
    fulldomain = subdomain.present? ? "#{subdomain}.#{domain}" : domain
    "https://#{fulldomain}#{path}"
  end

  sig { returns(String) }
  def metric_title
    "#{T.unsafe(self).metric_value} #{T.unsafe(self).metric_name}"
  end

  sig { returns(T::Boolean) }
  def is_commentable?
    false
  end

end
