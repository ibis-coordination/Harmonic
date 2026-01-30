# typed: true

class SearchQuery
  extend T::Sig

  # Constants for validation
  VALID_ITEM_TYPES = ["note", "decision", "commitment"].freeze
  VALID_SORT_FIELDS = [
    "created_at", "updated_at", "deadline", "title", "backlink_count", "link_count", "participant_count", "voter_count", "relevance",
  ].freeze
  VALID_NUMERIC_FIELDS = [
    "backlink_count", "link_count", "participant_count", "voter_count", "option_count", "comment_count",
  ].freeze
  VALID_GROUP_BYS = [
    "none", "item_type", "status", "created_by", "date_created", "week_created", "month_created", "date_deadline", "week_deadline", "month_deadline",
  ].freeze
  # Minimum word_similarity threshold for trigram matching
  # 0.3 is a good balance - matches partial words but filters noise
  WORD_SIMILARITY_THRESHOLD = 0.3

  sig do
    params(
      tenant: Tenant,
      current_user: T.nilable(User),
      superagent: T.nilable(Superagent),
      params: T::Hash[T.any(String, Symbol), T.untyped],
      raw_query: T.nilable(String)
    ).void
  end
  def initialize(tenant:, current_user:, superagent: nil, params: {}, raw_query: nil)
    @tenant = tenant
    @superagent = superagent
    @current_user = current_user
    @raw_query = raw_query
    @params = build_params(params)
  end

  private

  sig { params(params: T::Hash[T.any(String, Symbol), T.untyped]).returns(ActiveSupport::HashWithIndifferentAccess) }
  def build_params(params)
    base_params = params.with_indifferent_access

    # If raw_query is provided, parse DSL and merge
    if @raw_query.present?
      parsed = SearchQueryParser.new(@raw_query).parse
      # Parsed values override base params (DSL takes precedence)
      base_params.merge!(parsed.compact)
    end

    base_params
  end

  public

  # Main query methods

  sig { returns(ActiveRecord::Relation) }
  def results
    @results ||= build_query
  end

  sig { returns(ActiveRecord::Relation) }
  def paginated_results
    @paginated_results ||= begin
      relation = results
      relation = relation.where(search_index: { sort_key: ...cursor.to_i }) if cursor.present?
      relation.limit(per_page)
    end
  end

  sig { returns(T::Array[T::Array[T.untyped]]) }
  def grouped_results
    rows = paginated_results.to_a
    return [[nil, rows]] if group_by.nil? || group_by == "none"

    grouped = {}
    rows.each do |row|
      key = extract_group_key(row)
      grouped[key] ||= []
      grouped[key] << row
    end

    group_order.filter_map { |key| [key, grouped[key]] if grouped[key].present? }
  end

  sig { returns(Integer) }
  def total_count
    @total_count ||= results.count
  end

  sig { returns(T.nilable(String)) }
  def next_cursor
    last_item = paginated_results.to_a.last
    last_item&.sort_key&.to_s
  end

  # Parameter accessors (for view/controller)

  sig { returns(T.nilable(String)) }
  def query
    @query ||= @params[:q].to_s.strip.presence
  end

  sig { returns(String) }
  def sort_by
    @sort_by ||= @params[:sort_by].presence || "created_at-desc"
  end

  sig { returns(T.nilable(String)) }
  def group_by
    return @group_by if defined?(@group_by)

    requested = @params[:group_by].to_s.strip
    return @group_by = "item_type" if requested.blank?
    return @group_by = nil if requested == "none"

    @group_by = VALID_GROUP_BYS.include?(requested) ? requested : "item_type"
  end

  sig { returns(T.nilable(String)) }
  def cursor
    @params[:cursor].presence
  end

  sig { returns(Integer) }
  def per_page
    @per_page ||= begin
      val = @params[:per_page].to_i
      val = 25 if val <= 0
      val = 100 if val > 100
      val
    end
  end

  sig { returns(String) }
  def cycle_name
    @cycle_name ||= @params[:cycle].presence || "today"
  end

  sig { returns(T::Array[String]) }
  def types
    @types ||= parse_comma_list(@params[:type]).map(&:downcase)
  end

  sig { returns(T::Array[String]) }
  def filters
    @filters ||= parse_comma_list(@params[:filters])
  end

  sig { returns(T.nilable(String)) }
  def after_date
    @params[:after_date].presence
  end

  sig { returns(T.nilable(String)) }
  def before_date
    @params[:before_date].presence
  end

  sig { returns(T::Array[String]) }
  def exact_phrases
    @exact_phrases ||= Array(@params[:exact_phrases])
  end

  sig { returns(T::Array[String]) }
  def excluded_terms
    @excluded_terms ||= Array(@params[:excluded_terms])
  end

  sig { returns(T.nilable(String)) }
  attr_reader :raw_query

  # Options for UI dropdowns

  sig { returns(T::Array[T::Array[String]]) }
  def cycle_options
    [
      ["Today", "today"],
      ["Yesterday", "yesterday"],
      ["This week", "this-week"],
      ["Last week", "last-week"],
      ["This month", "this-month"],
      ["Last month", "last-month"],
      ["This year", "this-year"],
      ["Last year", "last-year"],
      ["All time", "all"],
    ]
  end

  sig { returns(T::Array[T::Array[String]]) }
  def sort_by_options
    options = [
      ["Created (newest)", "created_at-desc"],
      ["Created (oldest)", "created_at-asc"],
      ["Updated (newest)", "updated_at-desc"],
      ["Updated (oldest)", "updated_at-asc"],
      ["Deadline (soonest)", "deadline-asc"],
      ["Deadline (latest)", "deadline-desc"],
      ["Most backlinks", "backlink_count-desc"],
      ["Most participants", "participant_count-desc"],
      ["Title (A-Z)", "title-asc"],
      ["Title (Z-A)", "title-desc"],
    ]
    options.unshift(["Relevance", "relevance-desc"]) if query.present?
    options
  end

  sig { returns(T::Array[T::Array[String]]) }
  def group_by_options
    [
      ["Item type", "item_type"],
      ["None (flat list)", "none"],
      ["Status", "status"],
      ["Date created", "date_created"],
      ["Week created", "week_created"],
      ["Month created", "month_created"],
      ["Date deadline", "date_deadline"],
      ["Week deadline", "week_deadline"],
      ["Month deadline", "month_deadline"],
    ]
  end

  sig { returns(T::Array[T::Array[String]]) }
  def type_options
    [
      ["All types", "all"],
      ["Notes", "note"],
      ["Decisions", "decision"],
      ["Commitments", "commitment"],
    ]
  end

  sig { returns(T::Array[T::Array[String]]) }
  def filter_presets
    [
      ["None", ""],
      ["My items", "mine"],
      ["Open items", "open"],
      ["My open items", "mine,open"],
      ["Has backlinks", "has_backlinks"],
    ]
  end

  # To params for URL generation
  sig { returns(T::Hash[Symbol, T.untyped]) }
  def to_params
    # If raw_query was used, return it as the primary param
    return { q: @raw_query, cursor: @params[:cursor].presence }.compact_blank if @raw_query.present?

    # Legacy mode: return individual params
    {
      q: query,
      type: @params[:type].presence,
      cycle: cycle_name,
      filters: @params[:filters].presence,
      sort_by: sort_by,
      group_by: @params[:group_by].presence,
      per_page: per_page,
    }.compact_blank
  end

  private

  sig { returns(ActiveRecord::Relation) }
  def build_query
    @relation = SearchIndex.where(tenant_id: @tenant.id)

    # Apply superagent scope with access control
    # Always filter to accessible superagents to prevent information leakage
    accessible_ids = accessible_superagent_ids
    @relation = if @superagent.present?
                  # Scoped to specific superagent, but only if user has access
                  # If user doesn't have access, this returns no results (empty intersection)
                  @relation.where(superagent_id: accessible_ids & [@superagent.id])
                else
                  # Tenant-wide search: filter to all accessible superagents
                  @relation.where(superagent_id: accessible_ids)
                end

    apply_text_search
    apply_type_filter
    apply_time_window
    apply_basic_filters
    apply_sorting

    @relation
  end

  sig { returns(T::Array[String]) }
  def accessible_superagent_ids
    # All scenes (public) in tenant
    scene_ids = @tenant.superagents.where(superagent_type: "scene").pluck(:id)

    # Studios the user is a member of
    studio_ids = if @current_user.present?
                   @current_user.superagents
                     .where(tenant_id: @tenant.id, superagent_type: "studio")
                     .pluck(:id)
                 else
                   []
                 end

    scene_ids + studio_ids
  end

  sig { void }
  def apply_text_search
    apply_fuzzy_search
    apply_exact_phrase_search
    apply_excluded_terms
  end

  sig { void }
  def apply_fuzzy_search
    return if query.blank?

    quoted_query = SearchIndex.connection.quote(query)

    # Use pg_trgm word_similarity for trigram-based fuzzy matching
    # word_similarity() finds the search term as a complete word within the text
    # This handles all words including stop words that tsvector filters out
    @relation = T.must(@relation)
      .where("word_similarity(?, searchable_text) >= ?", query, WORD_SIMILARITY_THRESHOLD)

    return unless sort_field == "relevance"

    @relation = T.must(@relation)
      .select("search_index.*, word_similarity(#{quoted_query}, searchable_text) AS relevance_score")
  end

  sig { void }
  def apply_exact_phrase_search
    return if exact_phrases.blank?

    # Each exact phrase must appear as a substring (case-insensitive)
    exact_phrases.each do |phrase|
      @relation = T.must(@relation).where("searchable_text ILIKE ?", "%#{sanitize_like(phrase)}%")
    end
  end

  sig { void }
  def apply_excluded_terms
    return if excluded_terms.blank?

    # Results must NOT contain any excluded term (case-insensitive)
    excluded_terms.each do |term|
      @relation = T.must(@relation).where.not("searchable_text ILIKE ?", "%#{sanitize_like(term)}%")
    end
  end

  sig { params(value: String).returns(String) }
  def sanitize_like(value)
    # Escape special LIKE characters: % _ \
    value.gsub(/[%_\\]/) { |match| "\\#{match}" }
  end

  sig { void }
  def apply_type_filter
    return if types.blank? || types.include?("all")

    # Convert 'note' -> 'Note', 'decision' -> 'Decision', etc.
    type_values = types.map { |t| t.singularize.capitalize }
    valid_types = type_values & ["Note", "Decision", "Commitment"]

    @relation = T.must(@relation).where(item_type: valid_types) if valid_types.present?
  end

  sig { void }
  def apply_time_window
    # Explicit dates override cycle
    if after_date.present? || before_date.present?
      apply_explicit_dates
      return
    end

    return if cycle_name == "all"

    cycle_obj = cycle
    return if cycle_obj.blank?

    # Match the pattern from Cycle#resources:
    # created_at < end_date AND deadline > start_date
    @relation = T.must(@relation)
      .where(search_index: { created_at: ...cycle_obj.end_date })
      .where("search_index.deadline > ?", cycle_obj.start_date)
  end

  sig { void }
  def apply_explicit_dates
    if after_date.present?
      begin
        date = Date.parse(T.must(after_date))
        @relation = T.must(@relation).where(search_index: { created_at: date.beginning_of_day.. })
      rescue ArgumentError
        # Invalid date format, skip
      end
    end

    return if before_date.blank?

    begin
      date = Date.parse(T.must(before_date))
      @relation = T.must(@relation).where(search_index: { deadline: ..date.end_of_day })
    rescue ArgumentError
      # Invalid date format, skip
    end
  end

  sig { void }
  def apply_basic_filters
    filters.each do |filter|
      apply_single_filter(filter)
    end
  end

  sig { params(filter: String).void }
  def apply_single_filter(filter)
    case filter
    # Ownership filters
    when "mine"
      @relation = T.must(@relation).where(created_by_id: @current_user.id) if @current_user
    when "not_mine"
      @relation = T.must(@relation).where.not(created_by_id: @current_user.id) if @current_user
    when /^created_by:(.+)$/
      handle = T.must(Regexp.last_match(1))
      user = find_user_by_handle(handle)
      @relation = T.must(@relation).where(created_by_id: user&.id)

    # Status filters
    when "open"
      @relation = T.must(@relation).where("search_index.deadline > ?", Time.current)
    when "closed"
      @relation = T.must(@relation).where(search_index: { deadline: ..Time.current })

    # Presence filters
    when "has_backlinks"
      @relation = T.must(@relation).where("search_index.backlink_count > 0")
    when "has_links"
      @relation = T.must(@relation).where("search_index.link_count > 0")
    when "has_participants"
      @relation = T.must(@relation).where("search_index.participant_count > 0")
    when "updated"
      @relation = T.must(@relation).where("search_index.updated_at != search_index.created_at")
    end
  end

  sig { void }
  def apply_sorting
    field = sort_field
    direction = sort_direction

    field = "created_at" unless VALID_SORT_FIELDS.include?(field)
    direction = "desc" unless ["asc", "desc"].include?(direction)

    @relation = if field == "relevance" && query.present?
                  T.must(@relation).order(Arel.sql("relevance_score DESC"))
                else
                  T.must(@relation).order("search_index.#{field}" => direction.to_sym)
                end

    # Always add sort_key as secondary sort for pagination stability
    @relation = T.must(@relation).order("search_index.sort_key DESC")
  end

  sig { returns(String) }
  def sort_field
    sort_by.split("-").first || "created_at"
  end

  sig { returns(String) }
  def sort_direction
    sort_by.split("-").last || "desc"
  end

  sig { returns(T.nilable(Cycle)) }
  def cycle
    return @cycle if defined?(@cycle)
    return @cycle = nil if cycle_name == "all"
    # Cycle requires a superagent; for tenant-wide search, skip cycle filtering
    return @cycle = nil if @superagent.nil?

    @cycle = Cycle.new(
      name: cycle_name,
      tenant: @tenant,
      superagent: T.must(@superagent),
      current_user: @current_user
    )
  rescue StandardError
    @cycle = nil
  end

  sig { params(handle: String).returns(T.nilable(User)) }
  def find_user_by_handle(handle)
    tenant_user = @tenant.tenant_users.find_by(handle: handle)
    tenant_user&.user
  end

  sig { params(row: SearchIndex).returns(T.nilable(String)) }
  def extract_group_key(row)
    case group_by
    when "item_type"
      row.item_type
    when "status"
      row.status
    when "created_by"
      row.created_by&.name || "Unknown"
    when "date_created"
      row.date_created
    when "week_created"
      row.week_created
    when "month_created"
      row.month_created
    when "date_deadline"
      row.date_deadline
    when "week_deadline"
      row.week_deadline
    when "month_deadline"
      row.month_deadline
    end
  end

  sig { returns(T::Array[String]) }
  def group_order
    case group_by
    when "item_type"
      ["Note", "Decision", "Commitment"]
    when "status"
      ["open", "closed"]
    else
      # For date/time-based groupings, return keys in reverse chronological order
      paginated_results.to_a.map { |row| extract_group_key(row) }.compact.uniq
    end
  end

  sig { params(value: T.untyped).returns(T::Array[String]) }
  def parse_comma_list(value)
    raw = value.to_s.strip
    return [] if raw.blank?

    raw.split(",").map(&:strip)
  end
end
