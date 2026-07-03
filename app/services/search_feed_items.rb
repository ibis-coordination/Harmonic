# typed: true

# Converts SearchQuery results (SearchIndex rows) into the feed-item hashes
# the pulse feed partials render ({ type:, item:, created_at:, created_by: }),
# batch-loading the underlying records with their feed associations.
class SearchFeedItems
  extend T::Sig

  LOADERS = T.let({
    "Note" => ->(ids) { Note.where(id: ids).includes(:created_by, media_items: { file_attachment: :blob }) },
    "Decision" => ->(ids) { Decision.where(id: ids).includes(:created_by) },
    "Commitment" => ->(ids) { Commitment.where(id: ids).includes(:created_by) },
  }.freeze, T::Hash[String, T.untyped])

  sig { params(results: T::Enumerable[SearchIndex]).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.build(results)
    rows = results.to_a
    records = {}
    rows.group_by(&:item_type).each do |type, group|
      loader = LOADERS[type]
      next unless loader

      loader.call(group.map(&:item_id)).each { |record| records[[type, record.id]] = record }
    end

    rows.filter_map do |row|
      record = records[[row.item_type, row.item_id]]
      next nil unless record

      { type: row.item_type, item: record, created_at: record.created_at, created_by: record.created_by }
    end
  end
end
