# typed: true

class ApiToken < ApplicationRecord
  extend T::Sig

  self.implicit_order_column = "created_at"
  belongs_to :tenant
  belongs_to :user

  # Plaintext token is only available immediately after creation
  attr_accessor :plaintext_token

  # Clear plaintext_token on reload since it cannot be recovered from the database
  def reload(*args)
    self.plaintext_token = nil
    super
  end

  validates :token_hash, presence: true, uniqueness: true
  validates :scopes, presence: true
  validate :validate_scopes

  before_validation :generate_token_hash

  sig { returns(T::Array[String]) }
  def self.valid_actions
    ['create', 'read', 'update', 'delete']
  end

  sig { returns(T::Array[String]) }
  def valid_actions
    self.class.valid_actions
  end

  sig { returns(T::Array[String]) }
  def self.valid_resources
    ['all', 'notes', 'confirmations',
     'decisions', 'options', 'votes', 'decision_participants',
     'commitments', 'commitment_participants',
     'cycles', 'users', 'api_tokens']
  end

  sig { returns(T::Array[String]) }
  def valid_resources
    self.class.valid_resources
  end

  # TODO - remove the invalid scopes, e.g. 'create:cycles', 'update:results', etc.
  sig { returns(T::Array[String]) }
  def self.valid_scopes
    valid_actions.product(valid_resources).map { |a, r| "#{a}:#{r}" }
  end

  sig { returns(T::Array[String]) }
  def valid_scopes
    self.class.valid_scopes
  end

  sig { returns(T::Array[String]) }
  def self.read_scopes
    # valid_scopes.select { |scope| scope.start_with?('read') }
    ['read:all']
  end

  sig { returns(T::Array[String]) }
  def self.write_scopes
    # valid_scopes.select { |scope| scope.start_with?('create', 'update', 'delete') }
    ['create:all', 'update:all', 'delete:all']
  end

  sig { params(scope: String).returns(T::Boolean) }
  def self.valid_scope?(scope)
    action, resource = scope.split(':')
    valid_actions.include?(action) && valid_resources.include?(resource)
  end

  sig { params(include: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
  def api_json(include: [])
    # Return full plaintext token if still in memory (just created)
    # Otherwise return obfuscated token
    token_value = plaintext_token.present? ? plaintext_token : obfuscated_token

    {
      id: id,
      name: name,
      user_id: user_id,
      token: token_value,
      scopes: scopes,
      active: active?,
      expires_at: expires_at,
      last_used_at: last_used_at,
      created_at: created_at,
      updated_at: updated_at,
    }
  end

  sig { returns(String) }
  def obfuscated_token
    (token_prefix || "????") + "*********"
  end

  sig { returns(String) }
  def base_path
    "/u/#{T.must(user).handle}/settings/tokens"
  end

  sig { returns(String) }
  def path
    "#{base_path}/#{id}"
  end

  sig { returns(T::Boolean) }
  def active?
    !deleted? && !expired?
  end

  sig { returns(T::Boolean) }
  def expired?
    T.must(expires_at) < Time.current
  end

  sig { returns(T::Boolean) }
  def deleted?
    !deleted_at.nil?
  end

  sig { returns(T::Boolean) }
  def sys_admin?
    sys_admin == true
  end

  sig { returns(T::Boolean) }
  def app_admin?
    app_admin == true
  end

  sig { returns(T::Boolean) }
  def tenant_admin?
    tenant_admin == true
  end

  sig { void }
  def delete!
    self.deleted_at ||= T.cast(Time.current, ActiveSupport::TimeWithZone)
    save!
  end

  sig { void }
  def token_used!
    update!(last_used_at: Time.current)
  end

  sig { params(action: String, resource_model: T.nilable(T::Class[T.anything])).returns(T::Boolean) }
  def can?(action, resource_model)
    action = {
      'POST' => 'create', 'GET' => 'read', 'PUT' => 'update', 'PATCH' => 'update', 'DELETE' => 'delete'
    }[action] || action
    unless valid_actions.include?(action)
      raise "Invalid action: #{action}"
    end
    return true if T.must(scopes).include?('all') || T.must(scopes).include?("#{action}:all")
    return false if resource_model.nil?
    resource_name = resource_model.to_s.pluralize.downcase
    unless valid_resources.include?(resource_name)
      raise "Invalid resource: #{resource_name}"
    end
    unless resource_model.method_defined?(:api_json)
      raise "Resource model #{resource_model} does not respond to api_json"
    end
    T.must(scopes).include?("#{action}:#{resource_name}")
  end

  sig { params(resource_model: T::Class[T.anything]).returns(T::Boolean) }
  def can_create?(resource_model)
    can?('create', resource_model)
  end

  sig { params(resource_model: T::Class[T.anything]).returns(T::Boolean) }
  def can_read?(resource_model)
    can?('read', resource_model)
  end

  sig { params(resource_model: T::Class[T.anything]).returns(T::Boolean) }
  def can_update?(resource_model)
    can?('update', resource_model)
  end

  sig { params(resource_model: T::Class[T.anything]).returns(T::Boolean) }
  def can_delete?(resource_model)
    can?('delete', resource_model)
  end

  # Authenticate by hashing the provided token and looking up the hash
  sig { params(token_string: String, tenant_id: T.untyped).returns(T.nilable(ApiToken)) }
  def self.authenticate(token_string, tenant_id:)
    return nil if token_string.blank?

    token_hash = hash_token(token_string)
    find_by(token_hash: token_hash, deleted_at: nil, tenant_id: tenant_id)
  end

  sig { params(token_string: String).returns(String) }
  def self.hash_token(token_string)
    Digest::SHA256.hexdigest(token_string)
  end

  private

  sig { void }
  def generate_token_hash
    return if token_hash.present?

    # Generate a new random token
    new_token = SecureRandom.hex(20)

    # Store plaintext temporarily for returning to user on creation
    self.plaintext_token = new_token

    # Store the hash and prefix
    self.token_hash = self.class.hash_token(new_token)
    self.token_prefix = new_token[0..3]
  end

  sig { void }
  def validate_scopes
    T.must(scopes).each do |scope|
      action, resource = scope.split(':')
      unless ApiToken.valid_scope?(scope)
        errors.add(:scopes, "Invalid scope: #{scope}")
      end
    end
  end
end