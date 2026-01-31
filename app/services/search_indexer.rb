# typed: true

class SearchIndexer
  extend T::Sig

  INDEXABLE_TYPES = [Note, Decision, Commitment].freeze

  sig { params(item: T.any(Note, Decision, Commitment)).void }
  def self.reindex(item)
    new(item).reindex
  end

  sig { params(item: T.any(Note, Decision, Commitment)).void }
  def self.delete(item)
    new(item).delete
  end

  sig { params(item: T.any(Note, Decision, Commitment)).void }
  def initialize(item)
    @item = item
  end

  sig { void }
  def reindex
    SearchIndex.upsert(
      build_attributes,
      unique_by: [:tenant_id, :item_type, :item_id]
    )
  end

  sig { void }
  def delete
    SearchIndex.where(
      tenant_id: @item.tenant_id,
      item_type: @item.class.name,
      item_id: @item.id
    ).delete_all
  end

  private

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def build_attributes
    {
      tenant_id: @item.tenant_id,
      superagent_id: @item.superagent_id,
      item_type: @item.class.name,
      item_id: @item.id,
      truncated_id: @item.truncated_id,
      title: title,
      body: body,
      searchable_text: searchable_text,
      created_at: @item.created_at,
      updated_at: @item.updated_at,
      deadline: deadline,
      created_by_id: @item.created_by_id,
      updated_by_id: @item.updated_by_id,
      link_count: link_count,
      backlink_count: backlink_count,
      participant_count: participant_count,
      voter_count: voter_count,
      option_count: option_count,
      comment_count: comment_count,
      reader_count: reader_count,
      is_pinned: is_pinned,
      subtype: subtype,
      replying_to_id: replying_to_id,
    }
  end

  sig { returns(String) }
  def title
    result = case @item
             when Note, Commitment then @item.title
             when Decision then @item.question
             end
    result || ""
  end

  sig { returns(T.nilable(String)) }
  def body
    case @item
    when Note then @item.text
    when Decision, Commitment then @item.description
    end
  end

  sig { returns(String) }
  def searchable_text
    # For Notes, only include body since title is derived from text (avoids duplication).
    # For Decisions/Commitments, include both title and body since they're distinct fields.
    parts = @item.is_a?(Note) ? [body] : [title, body]

    # Include option titles for Decisions
    parts.concat(@item.options.pluck(:title)) if @item.is_a?(Decision)

    parts.compact.join(" ")
  end

  sig { returns(Integer) }
  def link_count
    Link.where(from_linkable: @item).count
  end

  sig { returns(Integer) }
  def backlink_count
    Link.where(to_linkable: @item).count
  end

  sig { returns(Integer) }
  def participant_count
    case @item
    when Note
      @item.confirmed_reads
    when Decision
      @item.participants.count
    when Commitment
      @item.participant_count
    else
      0
    end
  end

  sig { returns(Integer) }
  def voter_count
    @item.is_a?(Decision) ? @item.voter_count : 0
  end

  sig { returns(Integer) }
  def option_count
    @item.is_a?(Decision) ? @item.options.count : 0
  end

  sig { returns(Integer) }
  def comment_count
    @item.respond_to?(:comments) ? @item.comments.count : 0
  end

  sig { returns(Integer) }
  def reader_count
    @item.is_a?(Note) ? @item.confirmed_reads : 0
  end

  sig { returns(T::Boolean) }
  def is_pinned
    # Pinning is user/superagent-specific, so we can't store it at the item level.
    # This field is reserved for future use when we implement global pinning.
    false
  end

  sig { returns(T.any(Time, ActiveSupport::TimeWithZone)) }
  def deadline
    T.must(@item.deadline)
  end

  sig { returns(T.nilable(String)) }
  def subtype
    return "comment" if @item.is_a?(Note) && @item.is_comment?

    nil
  end

  sig { returns(T.nilable(String)) }
  def replying_to_id
    return nil unless @item.is_a?(Note) && @item.is_comment?

    # Get the created_by_id of the commentable (the item being replied to)
    @item.commentable&.created_by_id
  end
end
