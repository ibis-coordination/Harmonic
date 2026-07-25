# typed: true

# A declared electorate: who may vote on a decision, or who may propose options
# for one. A rule is a UNION of clauses — a user is eligible if any clause
# matches — so every clause only ever widens the set. That keeps a rule
# renderable as a plain sentence with no precedence to explain.
#
# Rules are stored as jsonb on Decision and edited as a whole value, never
# mutated in place (in-place mutation of a jsonb attribute is not dirty-tracked,
# so it would skip both the save and the audit entry).
#
#   {"any_of": [
#     {"type": "users", "user_ids": ["<uuid>", "<uuid>"]},
#     {"type": "role",  "role": "admin"},
#     {"type": "list",  "list_id": "<uuid>"}
#   ]}
#
# The agent-facing surfaces speak a compact equivalent, resolved to UUIDs on the
# way in so a stored rule never rots when someone is renamed:
#
#   users:alice,bob role:admin list:abc123
#
# This is a value object, not an ActiveRecord — `collective` is passed to the
# methods that need it rather than held, so the same rule can be resolved
# without carrying hidden state.
class EligibilityRule
  extend T::Sig

  class ParseError < StandardError; end

  CLAUSE_TYPES = ["open", "members", "role", "list", "users"].freeze
  # `open` and `members` cover everyone, so they are meaningless beside another
  # clause and rejected there rather than silently ignored.
  EXCLUSIVE_TYPES = ["open", "members"].freeze
  MAX_CLAUSES = 10
  MAX_USER_IDS = 200

  sig { returns(T::Array[T::Hash[String, T.untyped]]) }
  attr_reader :clauses

  sig { params(clauses: T::Array[T::Hash[String, T.untyped]]).void }
  def initialize(clauses)
    @clauses = clauses.freeze
  end

  sig { returns(EligibilityRule) }
  def self.default
    new([{ "type" => "open" }])
  end

  # Accepts a stored jsonb hash or the compact string grammar. Raises
  # ParseError for structurally unusable input; semantic problems (unknown
  # role, a list from another collective) are reported by #validation_errors so
  # a model can surface them as ordinary validation failures.
  sig { params(value: T.untyped, collective: T.nilable(Collective)).returns(EligibilityRule) }
  def self.parse(value, collective: nil)
    return value if value.is_a?(EligibilityRule)

    case value
    when String then parse_compact(value, collective: collective)
    when Hash   then parse_hash(value)
    else raise ParseError, "Eligibility rule must be a string or an object"
    end
  end

  sig { params(value: T::Hash[T.untyped, T.untyped]).returns(EligibilityRule) }
  def self.parse_hash(value)
    hash = value.deep_stringify_keys
    clauses = hash["any_of"]
    raise ParseError, "Eligibility rule must have an 'any_of' array" unless clauses.is_a?(Array)

    new(clauses.map { |clause| normalize_clause(clause) })
  end
  private_class_method :parse_hash

  sig { params(clause: T.untyped).returns(T::Hash[String, T.untyped]) }
  def self.normalize_clause(clause)
    raise ParseError, "Each eligibility clause must be an object" unless clause.is_a?(Hash)

    clause = clause.deep_stringify_keys
    normalized = { "type" => clause["type"] }
    normalized["role"] = clause["role"] if clause.key?("role")
    normalized["list_id"] = clause["list_id"] if clause.key?("list_id")
    normalized["user_ids"] = Array(clause["user_ids"]).uniq if clause.key?("user_ids")
    normalized
  end
  private_class_method :normalize_clause

  # "users:alice,bob role:admin list:abc123" — whitespace-separated clauses,
  # handles and truncated ids resolved against `collective`.
  sig { params(value: String, collective: T.nilable(Collective)).returns(EligibilityRule) }
  def self.parse_compact(value, collective: nil)
    tokens = value.strip.split(/\s+/).reject(&:empty?)
    raise ParseError, "Eligibility rule cannot be blank" if tokens.empty?

    new(tokens.map { |token| parse_compact_token(token, collective) })
  end
  private_class_method :parse_compact

  sig { params(token: String, collective: T.nilable(Collective)).returns(T::Hash[String, T.untyped]) }
  def self.parse_compact_token(token, collective)
    type, _, argument = token.partition(":")

    case type
    when "open", "members"
      raise ParseError, "'#{type}' does not take a value" if argument.present?

      { "type" => type }
    when "role"
      raise ParseError, "'role:' requires a role name" if argument.blank?

      { "type" => "role", "role" => argument }
    when "list"
      raise ParseError, "'list:' requires a list id" if argument.blank?

      { "type" => "list", "list_id" => resolve_list_id(argument, collective) }
    when "users"
      raise ParseError, "'users:' requires at least one handle" if argument.blank?

      handles = argument.split(",").map(&:strip).reject(&:empty?)
      { "type" => "users", "user_ids" => handles.map { |h| resolve_user_id(h, collective) }.uniq }
    else
      raise ParseError, "Unknown eligibility clause '#{token}'"
    end
  end
  private_class_method :parse_compact_token

  # Handles live on TenantUser, not User, so they resolve within the
  # collective's tenant. They are accepted as input only — the resolved UUID is
  # what gets stored, so a rule survives a rename.
  sig { params(handle: String, collective: T.nilable(Collective)).returns(String) }
  def self.resolve_user_id(handle, collective)
    return handle if uuid?(handle)
    raise ParseError, "Cannot resolve handle '#{handle}' without a collective" if collective.nil?

    tenant_user = TenantUser.tenant_scoped_only(T.must(collective.tenant_id)).find_by(handle: handle)
    raise ParseError, "No user with handle '#{handle}'" if tenant_user.nil?

    T.must(tenant_user.user_id)
  end
  private_class_method :resolve_user_id

  sig { params(reference: String, collective: T.nilable(Collective)).returns(String) }
  def self.resolve_list_id(reference, collective)
    return reference if uuid?(reference)

    scope = collective ? UserList.where(collective_id: collective.id) : UserList
    list = scope.find_by(truncated_id: reference)
    raise ParseError, "No list '#{reference}'" if list.nil?

    list.id
  end
  private_class_method :resolve_list_id

  sig { params(value: String).returns(T::Boolean) }
  def self.uuid?(value)
    value.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
  end

  sig { returns(T::Hash[String, T.untyped]) }
  def to_h
    { "any_of" => clauses.map(&:dup) }
  end

  sig { params(collective: T.nilable(Collective)).returns(String) }
  def to_s(collective: nil)
    clauses.map { |clause| compact_clause(clause, collective) }.join(" ")
  end

  # A user is eligible if ANY clause matches. A clause whose reference no longer
  # resolves — a deleted list, a removed user — matches nobody rather than
  # voiding the whole rule: under union semantics that narrows the electorate
  # instead of widening it, and it does not lock out voters who match a
  # different clause.
  sig { params(user: T.nilable(User), collective: Collective).returns(T::Boolean) }
  def matches?(user, collective:)
    return false if user.nil?

    clauses.any? { |clause| clause_matches?(clause, user, collective) }
  end

  sig { params(collective: Collective).returns(T::Array[String]) }
  def validation_errors(collective:)
    errors = []
    errors << "Eligibility must have at least one clause" if clauses.empty?
    errors << "Eligibility may have at most #{MAX_CLAUSES} clauses" if clauses.size > MAX_CLAUSES

    if clauses.size > 1 && clauses.any? { |c| EXCLUSIVE_TYPES.include?(c["type"]) }
      exclusive = clauses.map { |c| c["type"] }.find { |t| EXCLUSIVE_TYPES.include?(t) }
      errors << "'#{exclusive}' must be the only clause"
    end

    clauses.each { |clause| errors.concat(clause_errors(clause, collective)) }
    errors.uniq
  end

  # True when the rule imposes no restriction, so callers can skip reporting it.
  sig { returns(T::Boolean) }
  def open?
    clauses.any? { |clause| EXCLUSIVE_TYPES.include?(clause["type"]) }
  end

  sig { params(collective: Collective).returns(String) }
  def describe(collective:)
    return "Everyone with access" if clauses.any? { |c| EXCLUSIVE_TYPES.include?(c["type"]) }

    clauses.map { |clause| describe_clause(clause, collective) }.to_sentence(two_words_connector: " or ",
                                                                             last_word_connector: ", or ")
  end

  sig { params(other: T.untyped).returns(T::Boolean) }
  def ==(other)
    return false unless other.is_a?(EligibilityRule)

    other.to_h == to_h
  end

  private

  sig do
    params(clause: T::Hash[String, T.untyped], user: User, collective: Collective).returns(T::Boolean)
  end
  def clause_matches?(clause, user, collective)
    case clause["type"]
    when "open"
      true
    when "members"
      # Mirrors ActionAuthorization's :collective_member check so a collective
      # identity keeps the standing it has on every other action.
      collective.identity_user?(user) || collective.user_is_member?(user)
    when "role"
      collective.collective_members.find_by(user_id: user.id)&.has_role?(clause["role"]) || false
    when "list"
      list = UserList.find_by(id: clause["list_id"], collective_id: collective.id)
      return false if list.nil?

      list.user_list_members.exists?(user_id: user.id)
    when "users"
      Array(clause["user_ids"]).include?(user.id)
    else
      false
    end
  end

  sig { params(clause: T::Hash[String, T.untyped], collective: Collective).returns(T::Array[String]) }
  def clause_errors(clause, collective)
    case clause["type"]
    when "open", "members"
      []
    when "role"
      return ["Unknown role '#{clause["role"]}'"] unless CollectiveMember.valid_roles.include?(clause["role"])

      []
    when "list"
      return ["Eligibility list not found"] if UserList.find_by(id: clause["list_id"],
                                                                collective_id: collective.id).nil?

      []
    when "users"
      user_ids = Array(clause["user_ids"])
      return ["Eligibility must name at least one user"] if user_ids.empty?
      return ["Eligibility may name at most #{MAX_USER_IDS} users"] if user_ids.size > MAX_USER_IDS

      member_ids = collective.collective_members.where(user_id: user_ids).pluck(:user_id)
      missing = user_ids - member_ids
      return ["Eligibility names #{missing.size} user(s) who are not members of this collective"] if missing.any?

      []
    else
      ["Unknown clause type '#{clause["type"]}'"]
    end
  end

  sig { params(clause: T::Hash[String, T.untyped], collective: T.nilable(Collective)).returns(String) }
  def compact_clause(clause, collective)
    case clause["type"]
    when "role"
      "role:#{clause["role"]}"
    when "list"
      list = UserList.find_by(id: clause["list_id"])
      "list:#{list&.truncated_id || clause["list_id"]}"
    when "users"
      user_ids = Array(clause["user_ids"])
      handles = if collective
                  TenantUser.tenant_scoped_only(T.must(collective.tenant_id))
                    .where(user_id: user_ids).pluck(:user_id, :handle).to_h
                else
                  {}
                end
      "users:#{user_ids.map { |id| handles[id] || id }.join(",")}"
    else
      clause["type"].to_s
    end
  end

  sig { params(clause: T::Hash[String, T.untyped], collective: Collective).returns(String) }
  def describe_clause(clause, collective)
    case clause["type"]
    when "role"
      "anyone with the #{clause["role"]} role"
    when "list"
      list = UserList.find_by(id: clause["list_id"], collective_id: collective.id)
      list ? "anyone on #{list.display_name}" : "a list that no longer exists"
    when "users"
      users = User.where(id: Array(clause["user_ids"]))
      names = Array(clause["user_ids"]).filter_map { |id| users.find { |u| u.id == id }&.name }
      names.any? ? names.to_sentence : "no one"
    else
      "everyone with access"
    end
  end
end
