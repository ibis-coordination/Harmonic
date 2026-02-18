# typed: true

class Link < ApplicationRecord
  extend T::Sig

  include InvalidatesSearchIndex

  self.implicit_order_column = "created_at"
  belongs_to :tenant
  before_validation :set_tenant_id
  belongs_to :collective
  before_validation :set_collective_id

  belongs_to :from_linkable, polymorphic: true
  belongs_to :to_linkable, polymorphic: true

  validate :validate_tenant_and_collective_id
  validate :validate_linkables_are_different

  sig { void }
  def set_tenant_id
    return unless self.tenant_id.nil?
    from_tenant_id = T.unsafe(from_linkable).tenant_id
    to_tenant_id = T.unsafe(to_linkable).tenant_id
    if from_tenant_id != to_tenant_id
      errors.add(:base, "Cannot link objects from different tenants")
    end
    self.tenant_id = from_tenant_id
  end

  sig { void }
  def set_collective_id
    return unless self.collective_id.nil?
    from_collective_id = T.unsafe(from_linkable).collective_id
    to_collective_id = T.unsafe(to_linkable).collective_id
    if from_collective_id != to_collective_id
      errors.add(:base, "Cannot link objects from different collectives")
    end
    self.collective_id = from_collective_id
  end

  sig { void }
  def validate_tenant_and_collective_id
    if T.unsafe(from_linkable).tenant_id != tenant_id
      errors.add(:tenant_id, "must match the tenant of the from_linkable")
    end
    if T.unsafe(from_linkable).collective_id != collective_id
      errors.add(:collective_id, "must match the collective of the from_linkable")
    end
    if T.unsafe(to_linkable).tenant_id != tenant_id
      errors.add(:tenant_id, "must match the tenant of the to_linkable")
    end
    if T.unsafe(to_linkable).collective_id != collective_id
      errors.add(:collective_id, "must match the collective of the to_linkable")
    end
  end

  sig { void }
  def validate_linkables_are_different
    if from_linkable.nil? || to_linkable.nil?
      errors.add(:base, "Cannot link nil objects")
      return
    end
    if from_linkable == to_linkable
      errors.add(:base, "Cannot link an object to itself")
    end
  end

  sig { params(start_date: T.nilable(Time), end_date: T.nilable(Time), tenant_id: T.nilable(String), collective_id: T.nilable(String), limit: Integer).returns(T::Array[T.untyped]) }
  def self.backlink_leaderboard(start_date: nil, end_date: nil, tenant_id: nil, collective_id: nil, limit: 10)
    tenant_id ||= Tenant.current_id
    collective_id ||= Collective.current_id
    if tenant_id.nil?
      raise "Cannot call backlink_leaderboard without tenant_id"
    end
    if collective_id.nil?
      raise "Cannot call backlink_leaderboard without collective_id"
    end
    start_date = Time.current - 100.years if start_date.nil?
    end_date = Time.current if end_date.nil?
    safe_limit = limit.to_i
    sql = <<-SQL
      SELECT
        l.to_linkable_id AS id,
        l.to_linkable_type AS type,
        COALESCE(n.title, d.question, c.title) AS title,
        COUNT(*) AS count
      FROM
        links l
      LEFT JOIN
        notes n ON l.to_linkable_type = 'Note' AND l.tenant_id = n.tenant_id AND
                   l.collective_id = n.collective_id AND l.to_linkable_id = n.id
      LEFT JOIN
        decisions d ON l.to_linkable_type = 'Decision' AND l.tenant_id = d.tenant_id AND
                       l.collective_id = d.collective_id AND l.to_linkable_id = d.id
      LEFT JOIN
        commitments c ON l.to_linkable_type = 'Commitment' AND l.tenant_id = c.tenant_id AND
                         l.collective_id = c.collective_id AND l.to_linkable_id = c.id
      WHERE
        l.tenant_id = ? AND l.collective_id = ? AND
        l.created_at >= ? AND l.created_at <= ?
      GROUP BY
        l.to_linkable_id, l.to_linkable_type, n.title, d.question, c.title
      ORDER BY
        count DESC
      LIMIT
        #{safe_limit}
    SQL
    counts = Link.connection.exec_query(
      ActiveRecord::Base.send(:sanitize_sql_array, [sql, tenant_id, collective_id, start_date, end_date])
    )
    counts.to_a
  end

  private

  # Both linked items need reindexing:
  # - from_linkable: link_count changes
  # - to_linkable: backlink_count changes
  def search_index_items
    [from_linkable, to_linkable].compact
  end
end
