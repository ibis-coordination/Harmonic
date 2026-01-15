# typed: true

class Cycle
  extend T::Sig

  sig { returns(String) }
  attr_accessor :name

  sig { params(tempo: String).returns(T::Array[String]) }
  def self.end_of_cycle_options(tempo:)
    full_list = [
      'end of day today',
      'end of day tomorrow',
      'end of this week',
      'end of next week',
      'end of this month',
      'end of next month',
      'end of this year',
      'end of next year',
    ]
  end

  sig { params(end_of_cycle: String, tenant: Tenant, superagent: Superagent).returns(Cycle) }
  def self.new_from_end_of_cycle_option(end_of_cycle:, tenant:, superagent:)
    name = T.must(end_of_cycle.downcase.gsub(' ', '-').split(/end-of-(?:day-)?/).last)
    new(name: name, tenant: tenant, superagent: superagent)
  end

  sig { params(tenant: Tenant, superagent: Superagent).returns(Cycle) }
  def self.new_from_tempo(tenant:, superagent:)
    case superagent.tempo
    when 'daily'
      new(name: 'today', tenant: tenant, superagent: superagent)
    when 'weekly'
      new(name: 'this-week', tenant: tenant, superagent: superagent)
    when 'monthly'
      new(name: 'this-month', tenant: tenant, superagent: superagent)
    when 'yearly'
      new(name: 'this-year', tenant: tenant, superagent: superagent)
    else
      raise 'Invalid tempo'
    end
  end

  sig { params(superagent: Superagent).returns(Cycle) }
  def self.new_from_superagent(superagent)
    self.new_from_tempo(tenant: T.must(superagent.tenant), superagent: superagent)
  end

  # Backwards compatibility alias
  class << self
    alias_method :new_from_studio, :new_from_superagent
  end

  sig do
    params(
      name: String,
      tenant: Tenant,
      superagent: Superagent,
      params: T::Hash[Symbol, T.untyped],
      current_user: T.nilable(User)
    ).void
  end
  def initialize(name:, tenant:, superagent:, params: {}, current_user: nil)
    @name = name
    @tenant = tenant
    @superagent = superagent
    @params = params
    @current_user = current_user
    raise "Invalid tenant" if @tenant.nil?
    raise "Invalid superagent" if @superagent.nil?
  end

  sig { returns(String) }
  def previous_cycle
    case @name
    when 'today' then 'yesterday'
    when 'this-week' then 'last-week'
    when 'this-month' then 'last-month'
    else
      raise "Not implemented"
    end
  end

  sig { params(include: T::Array[String]).returns(T::Hash[Symbol, T.untyped]) }
  def api_json(include: [])
    response = {
      name: name,
      display_name: display_name,
      time_window: display_window,
      unit: unit,
      start_date: start_date,
      end_date: end_date,
      counts: counts,
    }
    if include.include?('notes')
      response.merge!({ notes: notes.map(&:api_json) })
    end
    if include.include?('decisions')
      response.merge!({ decisions: decisions.map(&:api_json) })
    end
    if include.include?('commitments')
      response.merge!({ commitments: commitments.map(&:api_json) })
    end
    if include.include?('backlinks')
      response.merge!({ backlinks: backlinks.map(&:api_json) })
    end
    response
  end

  sig { returns(String) }
  def display_name
    @name.titleize
  end

  sig { returns(String) }
  def path
    "#{@superagent.path}/cycles/#{@name}"
  end

  sig { returns(String) }
  def path_with_params
    p = {}
    # TODO - group_by, selections, cycle_name
    if params[:filters].present? && params[:filters] != 'none'
      p[:filters] = params[:filters]
    end
    if params[:sort_by].present?
      p[:sort_by] = params[:sort_by]
    end
    if p.empty?
      path
    else
      "#{path}?#{p.to_query}"
    end
  end

  sig { returns(T.nilable(String)) }
  def display_window
    case unit
    when 'day'
      start_date.strftime('%A, %B %-e, %Y')
    when 'week'
      "#{start_date.strftime('%B %-e')} - #{end_date.strftime('%B %-e, %Y')}"
    when 'month'
      start_date.strftime('%B %Y')
    when 'year'
      start_date.strftime('%Y')
    when 'custom'
      "#{start_date.strftime('%B %-e')} - #{end_date.strftime('%B %-e, %Y')}"
    end
  end

  sig { returns(T.nilable(String)) }
  def display_duration
    case unit
    when 'day'
      '1 day'
    when 'week'
      '1 week'
    when 'month'
      '1 month'
    when 'year'
      '1 year'
    when 'custom'
      # Largest unit first, e.g. 1 year, 2 months, 3 days
      duration = []
      duration << "#{(end_date - start_date).to_i / 365} year(s)" if (end_date - start_date).to_i >= 365
      duration << "#{(end_date - start_date).to_i % 365 / 30} month(s)" if (end_date - start_date).to_i % 365 >= 30
      duration << "#{(end_date - start_date).to_i % 30} day(s)" if (end_date - start_date).to_i % 30 > 0
      duration.join(', ')
    end
  end

  sig { returns(String) }
  def id
    "Cycles > #{display_name}"
  end

  sig { returns(String) }
  def truncated_id
    id
  end

  sig { returns(T.nilable(String)) }
  def unit
    return @unit if defined?(@unit)
    @unit = case @name
    when 'today'
      'day'
    when 'yesterday'
      'day'
    when 'tomorrow'
      'day'
    when 'this-week'
      'week'
    when 'last-week'
      'week'
    when 'next-week'
      'week'
    when 'this-month'
      'month'
    when 'last-month'
      'month'
    when 'next-month'
      'month'
    when 'this-year'
      'year'
    when 'last-year'
      'year'
    when 'next-year'
      'year'
    else
      # TODO hand year, month, week, day
      # e.g. 2020, 2020-01, 2020-week-1, 2020-01-01
    end
  end

  sig { returns(String) }
  def unit_for_custom_date
    return @unit_for_custom_date if defined?(@unit_for_custom_date)
    is_month_name = [
      'january', 'february', 'march',
      'april', 'may', 'june', 'july',
      'august', 'september', 'october',
      'november', 'december'
    ].include?(@name)
    @unit_for_custom_date = is_month_name ? 'month' : 'day'
  end

  sig { returns(ActiveSupport::TimeWithZone) }
  def now
    Time.current.in_time_zone(@superagent.timezone.name)
  end

  sig { returns(ActiveSupport::TimeWithZone) }
  def start_date
    return @start_date if defined?(@start_date)
    u = T.must(unit)
    if @name.starts_with?('last-') || @name == 'yesterday'
      relative_now = now - 1.send(u)
    elsif @name.starts_with?('next-') || @name == 'tomorrow'
      relative_now = now + 1.send(u)
    else
      relative_now = now
    end
    # @start_date = relative_now.in_time_zone(timezone).send("beginning_of_#{unit}")
    @start_date = relative_now.send("beginning_of_#{u}")
  end

  sig { returns(ActiveSupport::TimeWithZone) }
  def end_date
    return @end_date if defined?(@end_date)
    # @end_date = start_date.in_time_zone(timezone).send("end_of_#{unit}")
    @end_date = start_date + 1.send(T.must(unit))
  end

  sig { returns(T::Range[ActiveSupport::TimeWithZone]) }
  def window
    start_date..end_date
  end

  sig { params(model: T.class_of(ApplicationRecord)).returns(ActiveRecord::Relation) }
  def resources(model)
    # What if updated_at is after deadline?
    rs = model.where(tenant_id: @tenant.id, superagent_id: @superagent.id)
              .where("#{model.table_name}.created_at < ?", end_date)
              .where("#{model.table_name}.deadline > ?", start_date)
    current_filters = filters
    if current_filters.present?
      current_filters.each do |filter|
        rs = rs.where(filter)
      end
    end
    rs.order(sort_by)
  end

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def params
    @params
  end

  sig { returns(T::Array[String]) }
  def selections
    @selections ||= params[:selections].present? ? params[:selections].split(',') : [
      'title', 'created_at', 'created_by', 'deadline', 'backlink_count',
    ]
  end

  sig { returns(T::Array[T::Array[String]]) }
  def cycle_options
    [
      ['Today', 'today'],
      ['Yesterday', 'yesterday'],
      ['Tomorrow', 'tomorrow'],
      ['This week', 'this-week'],
      ['Last week', 'last-week'],
      ['Next week', 'next-week'],
      ['This month', 'this-month'],
      ['Last month', 'last-month'],
      ['Next month', 'next-month'],
      ['This year', 'this-year'],
      ['Last year', 'last-year'],
      ['Next year', 'next-year'],
    ]
  end

  sig { returns(T::Array[T::Array[String]]) }
  def sort_by_options
    [
      ['Deadline (earliest first)', 'deadline-asc'],
      ['Deadline (latest first)', 'deadline-desc'],
      ['Created (oldest first)', 'created_at-asc'],
      ['Created (newest first)', 'created_at-desc'],
      ['Updated (oldest first)', 'updated_at-asc'],
      ['Updated (most recent first)', 'updated_at-desc'],
    ]
  end

  sig { returns(T::Array[T::Array[String]]) }
  def group_by_options
    # [
    #   ['Item type', 'item_type'],
    #   ['Created by', 'created_by'],
    #   ['Deadline', 'deadline'],
    #   ['Updated', 'updated_at'],
    # ]
    CycleDataRow.valid_group_bys.map do |group_by|
      # [CycleDataRow.group_by_display_name(group_by), group_by]
      [group_by.titleize, group_by]
    end
  end

  sig { returns(T::Hash[String, String]) }
  def sort_by
    return @sort_by if @sort_by
    key, direction = (params[:sort_by] || 'created_at-desc').split('-')
    key = 'created_at' unless CycleDataRow.valid_sort_bys.include?(key)
    direction = 'desc' unless %w[asc desc].include?(direction)
    @sort_by = { key => direction }
  end

  sig { returns(String) }
  def group_by
    return @group_by if @group_by
    @group_by = CycleDataRow.valid_group_bys.include?(params[:group_by]) ? params[:group_by] : 'item_type'
  end

  sig { returns(T::Array[T::Array[String]]) }
  def filter_options
    dn = display_name.downcase
    past_cycle = end_date < now
    future_cycle = start_date > now
    current_cycle = start_date <= now && end_date >= now
    [
      ["None", 'none'],
      # Created
      ["Created by me", 'mine'],
      ["Not created by me", 'not_mine'],
      (past_cycle || current_cycle) ? ["Created #{dn}", 'new'] : nil,
      (past_cycle || current_cycle) ? ["Created before #{dn}", 'old'] : nil,
      # Open
      past_cycle ? ["Still open", 'open'] : nil,
      current_cycle ? ["Open", 'open'] : nil,
      current_cycle ? ["Open currently, closing #{dn}", 'closing_soon'] : nil,
      # Closed
      (past_cycle || current_cycle) ? ["Closed", 'closed'] : nil,
      current_cycle ? ["Closed or closing #{dn}", 'deadline_within_cycle'] : nil,
      past_cycle ? ["Closed #{dn}", 'deadline_within_cycle'] : nil,
      future_cycle ? ["Closing #{dn}", 'deadline_within_cycle'] : nil,
      (current_cycle || future_cycle) ? ["Closing after #{dn}", 'deadline_after_cycle'] : nil,
      # Updated
      ["Updated", 'updated'],
      (past_cycle || current_cycle) ? ["Updated #{dn}", 'updated_within_cycle'] : nil,
      (past_cycle || current_cycle) ? ["Created or updated #{dn}", 'created_or_updated_within_cycle'] : nil,
    ].compact
  end

  sig { returns(T.nilable(T::Array[T::Array[T.untyped]])) }
  def filters
    return @filters if defined?(@filters)
    return @filters = nil unless params[:filters].present?
    valid_keys = %w[created_by created_at updated_at deadline] + filter_options.map(&:last)
    @filters = params[:filters].split(',').map do |filter|
      key, value = filter.split(':')
      next if key == 'none'
      if value.nil?
        key, gt = key.split('>')
        key, lt = key.split('<') if gt.nil?
        next unless valid_keys.include?(key)
        if gt
          ["#{key} > ?", gt]
        elsif lt
          ["#{key} < ?", lt]
        elsif key == 'not_mine'
          ['created_by_id != ?', T.must(@current_user).id]
        elsif key == 'mine'
          ['created_by_id = ?', T.must(@current_user).id]
        elsif key == 'open'
          ['deadline > ?', Time.current]
        elsif key == 'closed'
          ['deadline < ?', Time.current]
        elsif key == 'closing_soon'
          ['deadline > ? and deadline <= ?', Time.current, self.end_date]
        elsif key == 'deadline_within_cycle'
          ['deadline > ? and deadline <= ?', self.start_date, self.end_date]
        elsif key == 'deadline_after_cycle'
          ['deadline > ?', self.end_date]
        elsif key == 'new'
          ['created_at > ?', self.start_date]
        elsif key == 'old'
          ['created_at < ?', self.start_date]
        elsif key == 'updated'
          ['updated_at != created_at']
        elsif key == 'updated_within_cycle'
          ['updated_at > ? and updated_at != created_at', self.start_date]
        elsif key == 'created_or_updated_within_cycle'
          ['created_at > ? or updated_at > ?', self.start_date, self.start_date]
        else
          raise "Invalid filter: #{key}"
        end
      elsif key == 'created_by'
        u = User.find_by(handle: value)
        u ? ['created_by_id = ?', u.id] : nil
      else
        next unless valid_keys.include?(key)
        ["#{key} = ?", value]
      end
    end.compact
  end

  sig { returns(ActiveRecord::Relation) }
  def notes
    @notes ||= resources(Note)
  end

  sig { params(user: User).returns(ActiveRecord::Relation) }
  def read_notes(user)
    @read_notes ||= T.unsafe(notes).where_user_has_read(user: user)
  end

  sig { params(user: User).returns(ActiveRecord::Relation) }
  def unread_notes(user)
    @unread_notes ||= notes.where.not(id: read_notes(user).pluck(:id))
  end

  sig { returns(ActiveRecord::Relation) }
  def decisions
    @decisions ||= resources(Decision)
  end

  sig { returns(ActiveRecord::Relation) }
  def open_decisions
    @open_decisions ||= decisions.where('deadline > ?', Time.current)
  end

  sig { returns(ActiveRecord::Relation) }
  def closed_decisions
    @closed_decisions ||= decisions.where('deadline < ?', Time.current)
  end

  sig { returns(ActiveRecord::Relation) }
  def decisions_closed_within_cycle
    @decisions_closed_within_cycle ||= decisions.where('deadline > ? and deadline <= ?', self.start_date, self.end_date)
  end

  sig { returns(ActiveRecord::Relation) }
  def commitments
    @commitments ||= resources(Commitment)
  end

  sig { returns(ActiveRecord::Relation) }
  def open_commitments
    @open_commitments ||= commitments.where('deadline > ?', Time.current)
  end

  sig { returns(ActiveRecord::Relation) }
  def closed_commitments
    @closed_commitments ||= commitments.where('deadline < ?', Time.current)
  end

  sig { returns(ActiveRecord::Relation) }
  def commitments_closed_within_cycle
    @commitments_closed_within_cycle ||= commitments.where('deadline > ? and deadline <= ?', self.start_date, self.end_date)
  end

  sig { returns(T::Hash[Symbol, Integer]) }
  def counts
    # TODO - make this more efficient for homepage query. Ideally in one query.
    @counts ||= {
      notes: notes.count,
      decisions: decisions.count,
      commitments: commitments.count,
    }
  end

  sig { returns(Integer) }
  def total_count
    counts.values.sum
  end

  sig { returns(T::Array[T.untyped]) }
  def backlinks
    # Link.backlink_leaderboard(start_date: start_date, end_date: end_date, tenant_id: @tenant.id)
    Link.where(tenant: @tenant, superagent: @superagent)
        .where(from_linkable: [notes, decisions, commitments].flatten)
        .includes(:to_linkable)
        .map(&:to_linkable).uniq
  end

  sig { returns(T::Array[T::Array[T.untyped]]) }
  def data_rows
    rows =  CycleDataRow.where(tenant_id: @tenant.id, superagent_id: @superagent.id)
                        .where('created_at < ?', end_date)
                        .where('deadline > ?', start_date)
    current_filters = filters
    if current_filters.present?
      current_filters.each do |filter|
        rows = rows.where(filter)
      end
    end
    grouped_rows = {}
    rows.order(sort_by).each do |row|
      row.cycle = self
      key = row.send(group_by)
      grouped_rows[key] ||= []
      grouped_rows[key] << selections.map do |selection|
        row.send(selection)
      end
    end
    groups = group_by == 'item_type' ? ['Note', 'Decision', 'Commitment'] : grouped_rows.keys.sort
    groups.map do |key|
      [key, grouped_rows[key] || []]
    end
  end


end