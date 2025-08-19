class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  before_validation :set_tenant_id
  before_validation :set_studio_id
  before_validation :set_updated_by

  default_scope do
    if belongs_to_tenant? && Tenant.current_id
      s = where(tenant_id: Tenant.current_id)
      if belongs_to_studio? && Studio.current_id
        s = s.where(studio_id: Studio.current_id)
      end
      s
    else
      all
    end
  end

  def self.belongs_to_tenant?
    self.column_names.include?("tenant_id")
  end

  def set_tenant_id
    if self.class.belongs_to_tenant?
      self.tenant_id ||= Tenant.current_id
    end
  end

  def self.belongs_to_studio?
    return false if self == StudioUser # This is a special case
    self.column_names.include?("studio_id")
  end

  def set_studio_id
    if self.class.belongs_to_studio?
      self.studio_id ||= Studio.current_id
    end
  end

  def self.is_tracked?
    false
  end

  def is_tracked?
    self.class.is_tracked?
  end

  def set_updated_by
    if self.class.column_names.include?("updated_by_id")
      self.updated_by_id ||= created_by_id
    end
  end

  def deadline_iso8601
    if deadline
      deadline.iso8601
    else
      ""
    end
  end

  def closed?
    deadline && deadline < Time.now
  end

  def user_can_close?(user)
    user.id == created_by.id
  end

  def requires_manual_close?
    # Deadline decades in the future represents intention to manually close in the future
    (deadline - Time.current) > 50.years
  end

  def path
    "#{studio.path}/#{path_prefix}/#{self.truncated_id}"
  end

  def shareable_link
    subdomain = self.tenant.subdomain
    domain = ENV['HOSTNAME']
    fulldomain = subdomain.present? ? "#{subdomain}.#{domain}" : domain
    "https://#{fulldomain}#{path}"
  end

  def metric_title
    "#{metric_value} #{metric_name}"
  end

end
