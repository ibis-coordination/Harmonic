# typed: true

class CycleDataRow < ApplicationRecord
  extend T::Sig

  self.primary_key = "item_id"
  self.table_name = "cycle_data" # view
  belongs_to :tenant
  belongs_to :superagent
  belongs_to :item, polymorphic: true
  belongs_to :created_by, class_name: 'User'
  belongs_to :updated_by, class_name: 'User'

  sig { returns(T::Array[String]) }
  def self.valid_group_bys
    self.valid_sort_bys + [
      'status', 'created_within_cycle', 'updated_within_cycle',
      'deadline_within_cycle', 'days_until_deadline',
      'date_created', 'date_updated', 'date_deadline',
      'week_created', 'week_updated', 'week_deadline',
      'month_created', 'month_updated', 'month_deadline',
      'year_created', 'year_updated', 'year_deadline',
    ]
  end

  sig { returns(T::Array[String]) }
  def self.valid_sort_bys
    self.column_names - ['tenant_id', 'superagent_id', 'item_id']
  end

  sig { params(cycle: Cycle).void }
  def cycle=(cycle)
    @cycle = cycle
  end

  sig { returns(T::Boolean) }
  def is_open
    T.must(deadline) > Time.now
  end

  sig { returns(String) }
  def status
    if is_open
      'open'
    else
      'closed'
    end
  end

  sig { returns(T::Boolean) }
  def created_within_cycle
    T.must(created_at) >= T.must(@cycle).start_date && T.must(created_at) <= T.must(@cycle).end_date
  end

  sig { returns(T::Boolean) }
  def updated_within_cycle
    T.must(updated_at) >= T.must(@cycle).start_date && T.must(updated_at) <= T.must(@cycle).end_date
  end

  sig { returns(T::Boolean) }
  def deadline_within_cycle
    T.must(deadline) >= T.must(@cycle).start_date && T.must(deadline) <= T.must(@cycle).end_date
  end

  sig { returns(Integer) }
  def days_until_deadline
    (T.must(deadline).to_date - Time.now.to_date).to_i
  end

  sig { params(timezone: String).void }
  def timezone=(timezone)
    @timezone = timezone
  end

  sig { returns(String) }
  def timezone
    @timezone ||= T.let(T.must(T.must(superagent).timezone).to_s, T.nilable(String))
    T.must(@timezone)
  end

  sig { returns(Date) }
  def date_created
    T.must(created_at).in_time_zone(timezone).to_date
  end

  sig { returns(Date) }
  def date_updated
    T.must(updated_at).in_time_zone(timezone).to_date
  end

  sig { returns(Date) }
  def date_deadline
    T.must(deadline).in_time_zone(timezone).to_date
  end

  sig { returns(String) }
  def week_created
    T.must(created_at).in_time_zone(timezone).strftime('%Y-%W')
  end

  sig { returns(String) }
  def week_updated
    T.must(updated_at).in_time_zone(timezone).strftime('%Y-%W')
  end

  sig { returns(String) }
  def week_deadline
    T.must(deadline).in_time_zone(timezone).strftime('%Y-%W')
  end

  sig { returns(String) }
  def month_created
    T.must(created_at).in_time_zone(timezone).strftime('%Y-%m')
  end

  sig { returns(String) }
  def month_updated
    T.must(updated_at).in_time_zone(timezone).strftime('%Y-%m')
  end

  sig { returns(String) }
  def month_deadline
    T.must(deadline).in_time_zone(timezone).strftime('%Y-%m')
  end

  sig { returns(String) }
  def year_created
    T.must(created_at).in_time_zone(timezone).strftime('%Y')
  end

  sig { returns(String) }
  def year_updated
    T.must(updated_at).in_time_zone(timezone).strftime('%Y')
  end

  sig { returns(String) }
  def year_deadline
    T.must(deadline).in_time_zone(timezone).strftime('%Y')
  end

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def api_json
    {
      item_type: item_type,
      item_id: item_id,
      title: title,
      created_at: created_at,
      updated_at: updated_at,
      created_by: created_by&.api_json,
      updated_by: updated_by&.api_json,
      deadline: deadline,
      link_count: link_count,
      backlink_count: backlink_count,
      participant_count: participant_count,
      voter_count: voter_count,
      option_count: option_count,
      status: status,
    }
  end

  sig { returns(T.untyped) }
  def item
    T.must(item_type).constantize.unscoped.find(item_id)
  end

  sig { params(superagent: Superagent).returns(String) }
  def item_path(superagent: T.must(self.superagent))
    # Allow passing in superagent to avoid reloading it
    # Would be ideal to load the item and call path on it, but that causes N + 1 queries
    "#{superagent.path}/#{T.must(item_type).downcase[0]}/#{T.must(item_id)[0..7]}"
  end

  sig { returns(T.nilable(String)) }
  def metric_name
    case item_type
    when 'Note'
      'readers'
    when 'Decision'
      'voters'
    when 'Commitment'
      'participants'
    end
  end

  sig { returns(T.nilable(Integer)) }
  def metric_value
    case item_type
    when 'Note'
      # TODO: Change this to readers
      participant_count
    when 'Decision'
      voter_count
    when 'Commitment'
      participant_count
    end
  end

  sig { returns(T.nilable(String)) }
  def octicon_metric_icon_name
    case item_type
    when 'Note'
      'book'
    when 'Decision'
      'check-circle'
    when 'Commitment'
      'person'
    end
  end

  sig { params(superagent: Superagent).returns(T::Hash[Symbol, T.untyped]) }
  def item_data_for_inline_display(superagent: T.must(self.superagent))
    # Allow passing in superagent to avoid reloading it
    {
      type: item_type,
      path: item_path(superagent: superagent),
      title: title,
      metric_name: metric_name,
      metric_value: metric_value,
      octicon_metric_icon_name: octicon_metric_icon_name,
    }
  end

  sig { returns(String) }
  def path
    item_path
  end
end