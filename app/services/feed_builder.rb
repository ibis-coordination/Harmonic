# typed: true

# Builds a unified feed of Notes, Decisions, and Commitments from provided scopes.
# Supports optional proximity-based ranking for personalized feeds.
class FeedBuilder
  extend T::Sig

  POOL_SIZE = 100
  DEFAULT_LIMIT = 30

  sig do
    params(
      notes_scope: ActiveRecord::Relation,
      decisions_scope: ActiveRecord::Relation,
      commitments_scope: ActiveRecord::Relation,
      limit: Integer,
      proximity_scores: T.nilable(T::Hash[String, Float])
    ).void
  end
  def initialize(notes_scope:, decisions_scope:, commitments_scope:,
                 limit: DEFAULT_LIMIT, proximity_scores: nil)
    @notes_scope = notes_scope
    @decisions_scope = decisions_scope
    @commitments_scope = commitments_scope
    @limit = limit
    @proximity_scores = proximity_scores
  end

  sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def feed_items
    @feed_items ||= build_feed
  end

  private

  sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def build_feed
    pool_size = @proximity_scores ? POOL_SIZE : @limit

    items = fetch_items(pool_size)

    items = rank_by_proximity(items) if @proximity_scores&.any?

    items.first(@limit)
  end

  sig { params(limit: Integer).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def fetch_items(limit)
    notes = @notes_scope
      .where(commentable_type: nil)
      .includes(:created_by)
      .order(created_at: :desc).limit(limit)
      .map { |n| { type: "Note", item: n, created_at: n.created_at, created_by: n.created_by } }

    decisions = @decisions_scope
      .includes(:created_by)
      .order(created_at: :desc).limit(limit)
      .map { |d| { type: "Decision", item: d, created_at: d.created_at, created_by: d.created_by } }

    commitments = @commitments_scope
      .includes(:created_by)
      .order(created_at: :desc).limit(limit)
      .map { |c| { type: "Commitment", item: c, created_at: c.created_at, created_by: c.created_by } }

    (notes + decisions + commitments).sort_by { |item| -item[:created_at].to_i }
  end

  sig { params(items: T::Array[T::Hash[Symbol, T.untyped]]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def rank_by_proximity(items)
    scores = T.must(@proximity_scores)
    max_proximity = scores.values.max || 1.0

    items.sort_by do |item|
      author_id = item[:created_by]&.id
      hours_ago = (Time.current - item[:created_at]).to_f / 3600
      recency = 1.0 / (1.0 + (hours_ago / 24.0))

      raw_proximity = author_id ? (scores[author_id] || 0.0) : 0.0
      normalized_proximity = raw_proximity / max_proximity

      score = recency * (1.0 + normalized_proximity)
      -score
    end
  end
end
