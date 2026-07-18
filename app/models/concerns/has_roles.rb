# typed: false

module HasRoles # TenantUser, CollectiveMember, ...
  extend ActiveSupport::Concern

  def roles
    settings['roles'] || []
  end

  def add_roles!(roles)
    return if roles.blank?
    raise "Invalid roles: #{roles - self.class.valid_roles}" unless (roles - self.class.valid_roles).empty?
    if roles.include?('representative') && self.user.collective_identity?
      raise "Collective identity users cannot be representatives"
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

  def is_summarizer?
    has_role?('summarizer')
  end

  def is_automator?
    has_role?('automator')
  end

  def is_moderator?
    has_role?('moderator')
  end

  class_methods do
    def where_has_role(role)
      where("settings->'roles' ? :role", role: role)
    end

    # Grantable through the role endpoints and pickers, by admins, to any
    # member. `automator` grants automation management (see
    # CollectiveMember#can_manage_automations?); `moderator` is a named role
    # that grants no capabilities yet — the moderation controls it will gate
    # are a separate feature.
    def capability_roles
      ['admin', 'representative', 'summarizer', 'automator', 'moderator']
    end

    # Reserved identity roles for the built-in agent personas. Managed only
    # by the persona activator (granted on activation, removed on
    # deactivation) — never grantable through the role endpoints. Mentions
    # resolve through them: @cadence → the member holding the cadence role
    # (ReservedHandles::AGENT_ROLES maps tag → persona role).
    def persona_roles
      ['melody', 'counterpoint', 'cadence']
    end

    # The shared Trio ensemble role, held by every ACTIVE persona alongside
    # its own persona role — @trio fans out to all of them. Same management
    # rules as persona roles: activator-only, never grantable.
    def ensemble_roles
      ['trio']
    end

    def valid_roles
      capability_roles + persona_roles + ensemble_roles
    end
  end
end
