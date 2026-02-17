# typed: false

module HasRoles # TenantUser, CollectiveMember, ...
  extend ActiveSupport::Concern

  def roles
    settings['roles'] || []
  end

  def add_roles!(roles)
    return if roles.blank?
    raise "Invalid roles: #{roles - self.class.valid_roles}" unless (roles - self.class.valid_roles).empty?
    if roles.include?('representative') && self.user.collective_proxy?
      raise "Collective proxy users cannot be representatives"
    end
    settings['roles'] ||= []
    settings['roles'] = settings['roles'] | roles
    save!
  end

  def add_role!(role)
    add_roles!([role])
  end

  def remove_roles!(roles)
    return if roles.blank?
    settings['roles'] ||= []
    settings['roles'] -= roles
    save!
  end

  def remove_role!(role)
    remove_roles!([role])
  end

  def has_role?(role)
    roles.include?(role)
  end

  def is_admin?
    has_role?('admin')
  end

  def is_representative?
    has_role?('representative')
  end

  class_methods do
    def where_has_role(role)
      where("settings->'roles' ? :role", role: role)
    end

    def valid_roles
      ['admin', 'representative']
    end
  end
end