# typed: false

class CycleDataRow < ApplicationRecord
  self.primary_key = "item_id"
  self.table_name = "cycle_data" # view
  belongs_to :tenant
  belongs_to :studio
  belongs_to :item, polymorphic: true
  belongs_to :created_by, class_name: 'User'
  belongs_to :updated_by, class_name: 'User'

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

  def self.valid_sort_bys
    self.column_names - ['tenant_id', 'studio_id', 'item_id']
  end

  def cycle=(cycle)
    @cycle = cycle
  end

  def is_open
    deadline > Time.now
  end

  def status
    if is_open
      'open'
    else
      'closed'
    end
  end

  def created_within_cycle
    created_at >= @cycle.start_date && created_at <= @cycle.end_date
  end

  def updated_within_cycle
    updated_at >= @cycle.start_date && updated_at <= @cycle.end_date
  end

  def deadline_within_cycle
    deadline >= @cycle.start_date && deadline <= @cycle.end_date
  end

  def days_until_deadline
    (deadline.to_date - Time.now.to_date).to_i
  end

  def timezone=(timezone)
    @timezone = timezone
  end

  def timezone
    @timezone ||= studio.timezone
  end

  def date_created
    created_at.in_time_zone(timezone).to_date
  end

  def date_updated
    updated_at.in_time_zone(timezone).to_date
  end

  def date_deadline
    deadline.in_time_zone(timezone).to_date
  end

  def week_created
    created_at.in_time_zone(timezone).strftime('%Y-%W')
  end

  def week_updated
    updated_at.in_time_zone(timezone).strftime('%Y-%W')
  end

  def week_deadline
    deadline.in_time_zone(timezone).strftime('%Y-%W')
  end

  def month_created
    created_at.in_time_zone(timezone).strftime('%Y-%m')
  end

  def month_updated
    updated_at.in_time_zone(timezone).strftime('%Y-%m')
  end

  def month_deadline
    deadline.in_time_zone(timezone).strftime('%Y-%m')
  end

  def year_created
    created_at.in_time_zone(timezone).strftime('%Y')
  end

  def year_updated
    updated_at.in_time_zone(timezone).strftime('%Y')
  end

  def year_deadline
    deadline.in_time_zone(timezone).strftime('%Y')
  end

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

  def item
    item_type.constantize.unscoped.find(item_id)
  end

  def item_path(studio: self.studio)
    # Allow passing in studio to avoid reloading it
    # Would be ideal to load the item and call path on it, but that causes N + 1 queries
    "#{studio.path}/#{item_type.downcase[0]}/#{item_id[0..7]}"
  end

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

  def item_data_for_inline_display(studio: self.studio)
    # Allow passing in studio to avoid reloading it
    {
      type: item_type,
      path: item_path(studio: studio),
      title: title,
      metric_name: metric_name,
      metric_value: metric_value,
      octicon_metric_icon_name: octicon_metric_icon_name,
    }
  end

  def path
    item_path
  end
end