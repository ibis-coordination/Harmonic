# typed: true

class SearchIndex < ApplicationRecord
  extend T::Sig

  self.table_name = "search_index"

  belongs_to :tenant
  belongs_to :superagent
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :updated_by, class_name: "User", optional: true

  # Virtual attribute for relevance scoring (set when searching with q parameter)
  attribute :relevance_score, :float

  validates :item_type, inclusion: { in: ["Note", "Decision", "Commitment"] }
  validates :item_id, presence: true
  validates :truncated_id, presence: true
  validates :title, presence: true
  validates :searchable_text, presence: true
  validates :deadline, presence: true

  sig { returns(String) }
  def path
    prefix = case item_type
             when "Note" then "n"
             when "Decision" then "d"
             when "Commitment" then "c"
             else raise "Unknown item type: #{item_type}"
             end
    "#{T.must(superagent).path}/#{prefix}/#{truncated_id}"
  end

  sig { returns(T::Boolean) }
  def is_open
    deadline > Time.current
  end

  sig { returns(String) }
  def status
    is_open ? "open" : "closed"
  end

  # Grouping helpers
  sig { returns(String) }
  def date_created
    created_at.to_date.to_s
  end

  sig { returns(String) }
  def week_created
    created_at.strftime("%Y-W%V")
  end

  sig { returns(String) }
  def month_created
    created_at.strftime("%Y-%m")
  end

  sig { returns(String) }
  def date_deadline
    deadline.to_date.to_s
  end

  sig { returns(String) }
  def week_deadline
    deadline.strftime("%Y-W%V")
  end

  sig { returns(String) }
  def month_deadline
    deadline.strftime("%Y-%m")
  end

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def api_json
    {
      item_type: item_type,
      item_id: item_id,
      truncated_id: truncated_id,
      title: title,
      body: body,
      path: path,
      created_at: created_at,
      updated_at: updated_at,
      deadline: deadline,
      is_open: is_open,
      backlink_count: backlink_count,
      link_count: link_count,
      participant_count: participant_count,
      voter_count: voter_count,
      option_count: option_count,
      comment_count: comment_count,
      reader_count: reader_count,
    }
  end

  # Load the actual item record
  sig { returns(T.nilable(T.any(Note, Decision, Commitment))) }
  def item
    @item ||= case item_type
              when "Note" then Note.find_by(id: item_id)
              when "Decision" then Decision.find_by(id: item_id)
              when "Commitment" then Commitment.find_by(id: item_id)
              end
  end
end
