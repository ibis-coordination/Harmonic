class ApiToken < ApplicationRecord
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  belongs_to :user

  validates :token, presence: true, uniqueness: true
  validates :scopes, presence: true
  validate :validate_scopes

  before_validation :generate_token

  def self.valid_actions
    ['create', 'read', 'update', 'delete']
  end

  def valid_actions
    self.class.valid_actions
  end

  def self.valid_resources
    ['all', 'notes', 'confirmations',
     'decisions', 'options', 'approvals', 'decision_participants',
     'commitments', 'commitment_participants',
     'cycles', 'users', 'api_tokens']
  end

  def valid_resources
    self.class.valid_resources
  end

  # TODO - remove the invalid scopes, e.g. 'create:cycles', 'update:results', etc.
  def self.valid_scopes
    valid_actions.product(valid_resources).map { |a, r| "#{a}:#{r}" }
  end

  def valid_scopes
    self.class.valid_scopes
  end

  def self.read_scopes
    # valid_scopes.select { |scope| scope.start_with?('read') }
    ['read:all']
  end

  def self.write_scopes
    # valid_scopes.select { |scope| scope.start_with?('create', 'update', 'delete') }
    ['create:all', 'update:all', 'delete:all']
  end

  def self.valid_scope?(scope)
    action, resource = scope.split(':')
    valid_actions.include?(action) && valid_resources.include?(resource)
  end

  def api_json(include: [])
    response = {
      id: id,
      name: name,
      user_id: user_id,
      token: obfuscated_token,
      scopes: scopes,
      active: active?,
      expires_at: expires_at,
      last_used_at: last_used_at,
      created_at: created_at,
      updated_at: updated_at,
    }
    if include.include?('full_token')
      response.merge!({ token: token })
    end
    response
  end

  def obfuscated_token
    token[0..3] + '*********'
  end

  def base_path
    "/u/#{user.handle}/settings/tokens"
  end

  def path
    "#{base_path}/#{id}"
  end

  def active?
    !deleted? && !expired?
  end

  def expired?
    expires_at < Time.current
  end

  def deleted?
    !deleted_at.nil?
  end

  def delete!
    self.deleted_at ||= Time.current
    save!
  end

  def token_used!
    update!(last_used_at: Time.current)
  end

  def can?(action, resource_model)
    action = {
      'POST' => 'create', 'GET' => 'read', 'PUT' => 'update', 'PATCH' => 'update', 'DELETE' => 'delete'
    }[action] || action
    unless valid_actions.include?(action)
      raise "Invalid action: #{action}"
    end
    return true if scopes.include?('all') || scopes.include?("#{action}:all")
    resource_name = resource_model.to_s.pluralize.downcase
    unless valid_resources.include?(resource_name)
      raise "Invalid resource: #{resource_name}"
    end
    unless resource_model.method_defined?(:api_json)
      raise "Resource model #{resource_model} does not respond to api_json"
    end
    scopes.include?("#{action}:#{resource_name}")
  end

  def can_create?(resource_model)
    can?('create', resource_model)
  end

  def can_read?(resource_model)
    can?('read', resource_model)
  end

  def can_update?(resource_model)
    can?('update', resource_model)
  end

  def can_delete?(resource_model)
    can?('delete', resource_model)
  end

  private

  def generate_token
    self.token ||= SecureRandom.hex(20)
  end

  def validate_scopes
    scopes.each do |scope|
      action, resource = scope.split(':')
      unless ApiToken.valid_scope?(scope)
        errors.add(:scopes, "Invalid scope: #{scope}")
      end
    end
  end
end