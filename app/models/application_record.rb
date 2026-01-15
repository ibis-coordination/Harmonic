# typed: true

class ApplicationRecord < ActiveRecord::Base
  extend T::Sig
  include SingleTenantMode

  primary_abstract_class

  before_validation :set_tenant_id
  before_validation :set_superagent_id
  before_validation :set_updated_by

  default_scope do
    if belongs_to_tenant? && Tenant.current_id
      s = where(tenant_id: Tenant.current_id)
      if belongs_to_superagent? && Superagent.current_id
        s = s.where(superagent_id: Superagent.current_id)
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
  def self.belongs_to_superagent?
    return false if self == SuperagentMember # This is a special case
    self.column_names.include?("superagent_id")
  end

  sig { void }
  def set_superagent_id
    if self.class.belongs_to_superagent?
      T.unsafe(self).superagent_id ||= Superagent.current_id
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
    "#{T.unsafe(self).superagent.path}/#{T.unsafe(self).path_prefix}/#{T.unsafe(self).truncated_id}"
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
