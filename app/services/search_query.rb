# typed: true

class SearchQuery
  extend T::Sig

  # Constants for validation
  VALID_ITEM_TYPES = ["note", "decision", "commitment"].freeze
  VALID_SORT_FIELDS = [
    "created_at", "updated_at", "deadline", "title", "backlink_count", "link_count", "participant_count", "voter_count", "reader_count", "relevance",
  ].freeze
  VALID_NUMERIC_FIELDS = [
    "backlink_count", "link_count", "participant_count", "voter_count", "option_count", "comment_count", "reader_count",
  ].freeze
  VALID_GROUP_BYS = [
    "none", "item_type", "status", "collective", "creator", "date_created", "week_created", "month_created", "date_deadline", "week_deadline", "month_deadline",
  ].freeze
  # Minimum word_similarity threshold for trigram matching
  # 0.3 is a good balance - matches partial words but filters noise
  WORD_SIMILARITY_THRESHOLD = 0.3

  sig do
    params(
      tenant: Tenant,
      current_user: T.nilable(User),
      collective: T.nilable(Collective),
      params: T::Hash[T.any(String, Symbol), T.untyped],
      raw_query: T.nilable(String)
    ).void
  end
  def initialize(tenant:, current_user:, collective: nil, params: {}, raw_query: nil)
    @tenant = tenant
    @collective = collective
    @current_user = current_user
    @raw_query = raw_query
    @params = build_params(params)

    # Resolve collective from studio:/scene: DSL operators
    resolve_collective_from_handle
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
      relation = apply_cursor_pagination(relation) if cursor.present?
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
    # Use except(:select) to avoid SQL syntax errors when custom SELECT includes AS clauses
    @total_count ||= results.except(:select).count
  end

  sig { returns(T.nilable(String)) }
  def next_cursor
    last_item = paginated_results.to_a.last
    return nil if last_item.nil?

    # Build compound cursor: "sort_field_value:sort_key"
    # This enables proper keyset pagination regardless of sort field
    field = effective_sort_field
    sort_key = last_item.sort_key

    field_value = if field == "relevance"
                    # relevance_score is a computed column from the SELECT
                    last_item.try(:relevance_score)&.to_f
                  else
                    last_item.public_send(field)
                  end

    # Encode as "field_value:sort_key" - use Base64 for field_value to handle special chars
    encoded_value = Base64.urlsafe_encode64(field_value.to_s, padding: false)
    "#{encoded_value}:#{sort_key}"
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
    return @group_by = "collective" if requested.blank?
    return @group_by = nil if requested == "none"

    @group_by = VALID_GROUP_BYS.include?(requested) ? requested : "collective"
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

  sig { returns(T.nilable(String)) }
  def studio_handle
    @params[:studio_handle].presence
  end

  sig { returns(T.nilable(String)) }
  def scene_handle
    @params[:scene_handle].presence
  end

  sig { returns(T.nilable(Collective)) }
  attr_reader :collective

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
      ["Studio/Scene", "collective"],
      ["Creator", "creator"],
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

  sig { void }
  def resolve_collective_from_handle
    return if @collective.present? # Already have a collective object

    # Check for studio: or scene: handle
    handle = studio_handle || scene_handle
    return if handle.blank?

    collective_type = studio_handle.present? ? "studio" : "scene"

    # Look up collective by handle and type within the tenant
    @collective = @tenant.collectives.find_by(handle: handle, collective_type: collective_type)
  end

  sig { returns(ActiveRecord::Relation) }
  def build_query
    # Require a query to show results - empty search page shows nothing
    return SearchIndex.none if @raw_query.blank?

    # Use tenant_scoped_only to bypass collective scope while keeping tenant scope
    # We handle collective filtering explicitly below with accessible_collective_ids
    @relation = SearchIndex.tenant_scoped_only(@tenant.id)

    # Apply collective scope with access control
    # Always filter to accessible collectives to prevent information leakage
    accessible_ids = accessible_collective_ids
    @relation = if @collective.present?
                  # Scoped to specific collective, but only if user has access
                  # If user doesn't have access, this returns no results (empty intersection)
                  @relation.where(collective_id: accessible_ids & [@collective.id])
                else
                  # Tenant-wide search: filter to all accessible collectives
                  @relation.where(collective_id: accessible_ids)
                end

    apply_text_search
    apply_type_filter
    apply_subtype_filter
    apply_status_filter
    apply_time_window
    apply_basic_filters
    apply_user_filters
    apply_integer_filters
    apply_boolean_filters
    apply_sorting

    # Eager load associations to avoid N+1 queries when grouping or displaying results
    @relation = T.must(@relation).includes(:collective, :created_by)

    @relation
  end

  sig { returns(T::Array[String]) }
  def accessible_collective_ids
    # All scenes (public) in tenant
    scene_ids = @tenant.collectives.where(collective_type: "scene").pluck(:id)

    # Studios the user is a member of
    studio_ids = if @current_user.present?
                   @current_user.collectives
                     .where(tenant_id: @tenant.id, collective_type: "studio")
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
    apply_type_inclusion_filter
    apply_type_exclusion_filter
  end

  sig { void }
  def apply_type_inclusion_filter
    return if types.blank? || types.include?("all")

    # Convert 'note' -> 'Note', 'decision' -> 'Decision', etc.
    type_values = types.map { |t| t.singularize.capitalize }
    valid_types = type_values & ["Note", "Decision", "Commitment"]

    @relation = T.must(@relation).where(item_type: valid_types) if valid_types.present?
  end

  sig { void }
  def apply_type_exclusion_filter
    exclude_types = Array(@params[:exclude_types])
    return if exclude_types.blank?

    # Convert 'note' -> 'Note', 'decision' -> 'Decision', etc.
    type_values = exclude_types.map { |t| t.singularize.capitalize }
    valid_types = type_values & ["Note", "Decision", "Commitment"]

    @relation = T.must(@relation).where.not(item_type: valid_types) if valid_types.present?
  end

  sig { void }
  def apply_subtype_filter
    # subtype:comment - only show comments
    subtypes = Array(@params[:subtypes])
    @relation = T.must(@relation).where(subtype: subtypes) if subtypes.present?

    # -subtype:comment - exclude comments (or other subtypes)
    exclude_subtypes = Array(@params[:exclude_subtypes])
    return if exclude_subtypes.blank?

    # Must use explicit NULL handling: regular notes have subtype = NULL,
    # and SQL's NULL != 'comment' returns NULL (not true), excluding those rows
    exclude_subtypes.each do |subtype|
      @relation = T.must(@relation).where("search_index.subtype IS NULL OR search_index.subtype != ?", subtype)
    end
  end

  sig { void }
  def apply_status_filter
    status = @params[:status].to_s.strip
    return if status.blank?

    case status
    when "open"
      @relation = T.must(@relation).where("search_index.deadline > ?", Time.current)
    when "closed"
      @relation = T.must(@relation).where(search_index: { deadline: ..Time.current })
    end
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

    # Status filters (legacy - now handled by apply_status_filter)
    when "open"
      @relation = T.must(@relation).where("search_index.deadline > ?", Time.current)
    when "closed"
      @relation = T.must(@relation).where(search_index: { deadline: ..Time.current })

    # Presence filters (legacy - now handled by integer min/max)
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
  def apply_user_filters
    apply_creator_filter
    apply_read_by_filter
    apply_voter_filter
    apply_participant_filter
    apply_mentions_filter
    apply_replying_to_filter
  end

  sig { void }
  def apply_creator_filter
    # creator:@handle - items created by these users
    creator_handles = Array(@params[:creator_handles])
    if creator_handles.present?
      user_ids = find_user_ids_by_handles(creator_handles)
      @relation = T.must(@relation).where(created_by_id: user_ids)
    end

    # -creator:@handle - items NOT created by these users
    exclude_creator_handles = Array(@params[:exclude_creator_handles])
    return if exclude_creator_handles.blank?

    exclude_user_ids = find_user_ids_by_handles(exclude_creator_handles)
    @relation = T.must(@relation).where.not(created_by_id: exclude_user_ids)
  end

  sig { void }
  def apply_read_by_filter
    # read-by:@handle - items read by these users
    read_by_handles = Array(@params[:read_by_handles])
    if read_by_handles.present?
      user_ids = find_user_ids_by_handles(read_by_handles)
      @relation = T.must(@relation)
        .joins("INNER JOIN user_item_status ON user_item_status.item_id = search_index.item_id
                AND user_item_status.item_type = search_index.item_type
                AND user_item_status.tenant_id = search_index.tenant_id")
        .where(user_item_status: { user_id: user_ids, has_read: true })
    end

    # -read-by:@handle - items NOT read by these users
    exclude_read_by_handles = Array(@params[:exclude_read_by_handles])
    return if exclude_read_by_handles.blank?

    exclude_user_ids = find_user_ids_by_handles(exclude_read_by_handles)
    # Use NOT EXISTS subquery to find items where none of the specified users have read
    @relation = T.must(@relation)
      .where.not(
        "EXISTS (SELECT 1 FROM user_item_status uis
                 WHERE uis.item_id = search_index.item_id
                 AND uis.item_type = search_index.item_type
                 AND uis.tenant_id = search_index.tenant_id
                 AND uis.user_id IN (?)
                 AND uis.has_read = true)", exclude_user_ids
      )
  end

  sig { void }
  def apply_voter_filter
    # voter:@handle - decisions voted on by these users
    voter_handles = Array(@params[:voter_handles])
    if voter_handles.present?
      user_ids = find_user_ids_by_handles(voter_handles)
      @relation = T.must(@relation)
        .joins("INNER JOIN user_item_status ON user_item_status.item_id = search_index.item_id
                AND user_item_status.item_type = search_index.item_type
                AND user_item_status.tenant_id = search_index.tenant_id")
        .where(user_item_status: { user_id: user_ids, has_voted: true })
    end

    # -voter:@handle - decisions NOT voted on by these users
    exclude_voter_handles = Array(@params[:exclude_voter_handles])
    return if exclude_voter_handles.blank?

    exclude_user_ids = find_user_ids_by_handles(exclude_voter_handles)
    @relation = T.must(@relation)
      .where.not(
        "EXISTS (SELECT 1 FROM user_item_status uis
                 WHERE uis.item_id = search_index.item_id
                 AND uis.item_type = search_index.item_type
                 AND uis.tenant_id = search_index.tenant_id
                 AND uis.user_id IN (?)
                 AND uis.has_voted = true)", exclude_user_ids
      )
  end

  sig { void }
  def apply_participant_filter
    # participant:@handle - commitments joined by these users
    participant_handles = Array(@params[:participant_handles])
    if participant_handles.present?
      user_ids = find_user_ids_by_handles(participant_handles)
      @relation = T.must(@relation)
        .joins("INNER JOIN user_item_status ON user_item_status.item_id = search_index.item_id
                AND user_item_status.item_type = search_index.item_type
                AND user_item_status.tenant_id = search_index.tenant_id")
        .where(user_item_status: { user_id: user_ids, is_participating: true })
    end

    # -participant:@handle - commitments NOT joined by these users
    exclude_participant_handles = Array(@params[:exclude_participant_handles])
    return if exclude_participant_handles.blank?

    exclude_user_ids = find_user_ids_by_handles(exclude_participant_handles)
    @relation = T.must(@relation)
      .where.not(
        "EXISTS (SELECT 1 FROM user_item_status uis
                 WHERE uis.item_id = search_index.item_id
                 AND uis.item_type = search_index.item_type
                 AND uis.tenant_id = search_index.tenant_id
                 AND uis.user_id IN (?)
                 AND uis.is_participating = true)", exclude_user_ids
      )
  end

  sig { void }
  def apply_mentions_filter
    # mentions:@handle - items that mention these users
    mentions_handles = Array(@params[:mentions_handles])
    if mentions_handles.present?
      user_ids = find_user_ids_by_handles(mentions_handles)
      @relation = T.must(@relation)
        .joins("INNER JOIN user_item_status ON user_item_status.item_id = search_index.item_id
                AND user_item_status.item_type = search_index.item_type
                AND user_item_status.tenant_id = search_index.tenant_id")
        .where(user_item_status: { user_id: user_ids, is_mentioned: true })
    end

    # -mentions:@handle - items that do NOT mention these users
    exclude_mentions_handles = Array(@params[:exclude_mentions_handles])
    return if exclude_mentions_handles.blank?

    exclude_user_ids = find_user_ids_by_handles(exclude_mentions_handles)
    @relation = T.must(@relation)
      .where.not(
        "EXISTS (SELECT 1 FROM user_item_status uis
                 WHERE uis.item_id = search_index.item_id
                 AND uis.item_type = search_index.item_type
                 AND uis.tenant_id = search_index.tenant_id
                 AND uis.user_id IN (?)
                 AND uis.is_mentioned = true)", exclude_user_ids
      )
  end

  sig { void }
  def apply_replying_to_filter
    # replying-to:@handle - comments that reply to content created by these users
    replying_to_handles = Array(@params[:replying_to_handles])
    if replying_to_handles.present?
      user_ids = find_user_ids_by_handles(replying_to_handles)
      @relation = T.must(@relation).where(replying_to_id: user_ids)
    end

    # -replying-to:@handle - items NOT replying to content by these users
    exclude_replying_to_handles = Array(@params[:exclude_replying_to_handles])
    return if exclude_replying_to_handles.blank?

    exclude_user_ids = find_user_ids_by_handles(exclude_replying_to_handles)
    # Exclude items that reply to these users (includes non-comments which have nil replying_to_id)
    @relation = T.must(@relation).where.not(replying_to_id: exclude_user_ids)
  end

  sig { void }
  def apply_integer_filters
    # Min/max filters for counts
    apply_count_filter("link_count", @params[:min_links], @params[:max_links])
    apply_count_filter("backlink_count", @params[:min_backlinks], @params[:max_backlinks])
    apply_count_filter("comment_count", @params[:min_comments], @params[:max_comments])
    apply_count_filter("reader_count", @params[:min_readers], @params[:max_readers])
    apply_count_filter("voter_count", @params[:min_voters], @params[:max_voters])
    apply_count_filter("participant_count", @params[:min_participants], @params[:max_participants])
  end

  sig { params(column: String, min_val: T.untyped, max_val: T.untyped).void }
  def apply_count_filter(column, min_val, max_val)
    @relation = T.must(@relation).where("search_index.#{column} >= ?", min_val.to_i) if min_val.present?

    return if max_val.blank?

    @relation = T.must(@relation).where("search_index.#{column} <= ?", max_val.to_i)
  end

  sig { void }
  def apply_boolean_filters
    # critical-mass-achieved:true/false
    critical_mass = @params[:critical_mass_achieved]
    return if critical_mass.nil?

    @relation = if critical_mass
                  # Commitments where participant_count >= critical_mass threshold
                  # Since critical_mass threshold is stored on the commitment itself, we need to join
                  # For now, use a simple heuristic: participant_count > 0 means some progress
                  # TODO: Join to commitments table to compare with actual threshold
                  T.must(@relation)
                    .where(item_type: "Commitment")
                    .where("search_index.participant_count > 0")
                else
                  # Commitments that have NOT reached critical mass
                  T.must(@relation)
                    .where(item_type: "Commitment")
                end
  end

  sig { void }
  def apply_sorting
    field = sort_field
    direction = sort_direction

    field = "created_at" unless VALID_SORT_FIELDS.include?(field)
    direction = "desc" unless ["asc", "desc"].include?(direction)

    # Relevance sorting requires a text query; fall back to created_at if no query
    if field == "relevance" && query.blank?
      field = "created_at"
      direction = "desc"
    end

    @relation = if field == "relevance"
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

  # Returns the effective sort field, handling the relevance fallback
  sig { returns(String) }
  def effective_sort_field
    field = sort_field
    # Relevance sorting requires a text query; fall back to created_at if no query
    return "created_at" if field == "relevance" && query.blank?

    field
  end

  # Returns the effective sort direction
  sig { returns(String) }
  def effective_sort_direction
    field = sort_field
    direction = sort_direction
    # Relevance sorting requires a text query; fall back to desc if no query
    return "desc" if field == "relevance" && query.blank?

    direction
  end

  # Parse compound cursor and apply keyset pagination
  sig { params(relation: ActiveRecord::Relation).returns(ActiveRecord::Relation) }
  def apply_cursor_pagination(relation)
    return relation if cursor.blank?

    # Parse compound cursor: "base64_encoded_value:sort_key"
    parts = cursor.to_s.split(":", 2)
    return relation if parts.length != 2

    encoded_value, sort_key_str = parts
    sort_key = T.must(sort_key_str).to_i

    begin
      field_value_str = Base64.urlsafe_decode64(T.must(encoded_value))
    rescue ArgumentError
      # Invalid base64, fall back to simple sort_key pagination
      return relation.where(search_index: { sort_key: ...sort_key })
    end

    field = effective_sort_field
    direction = effective_sort_direction

    # Convert field value to appropriate type
    field_value = parse_cursor_field_value(field, field_value_str)

    # Build keyset pagination condition:
    # For DESC: (field < value) OR (field = value AND sort_key < sort_key_cursor)
    # For ASC:  (field > value) OR (field = value AND sort_key < sort_key_cursor)
    # Note: sort_key is always DESC for tiebreaker
    if field == "relevance"
      # Relevance is a computed column, need to use the expression
      apply_relevance_cursor(relation, field_value, sort_key)
    else
      apply_field_cursor(relation, field, field_value, sort_key, direction)
    end
  end

  sig { params(field: String, value_str: String).returns(T.untyped) }
  def parse_cursor_field_value(field, value_str)
    case field
    when "created_at", "updated_at", "deadline"
      Time.zone.parse(value_str) rescue Time.current
    when "backlink_count", "link_count", "participant_count", "voter_count", "reader_count"
      value_str.to_i
    when "relevance"
      value_str.to_f
    when "title"
      value_str
    else
      value_str
    end
  end

  sig { params(relation: ActiveRecord::Relation, relevance_value: Float, sort_key: Integer).returns(ActiveRecord::Relation) }
  def apply_relevance_cursor(relation, relevance_value, sort_key)
    quoted_query = SearchIndex.connection.quote(query)
    # Relevance is always DESC
    relation.where(
      "(word_similarity(#{quoted_query}, searchable_text) < ?) OR " \
      "(word_similarity(#{quoted_query}, searchable_text) = ? AND search_index.sort_key < ?)",
      relevance_value, relevance_value, sort_key
    )
  end

  sig do
    params(
      relation: ActiveRecord::Relation,
      field: String,
      field_value: T.untyped,
      sort_key: Integer,
      direction: String
    ).returns(ActiveRecord::Relation)
  end
  def apply_field_cursor(relation, field, field_value, sort_key, direction)
    column = "search_index.#{field}"
    comparator = direction == "desc" ? "<" : ">"

    relation.where(
      "(#{column} #{comparator} ?) OR (#{column} = ? AND search_index.sort_key < ?)",
      field_value, field_value, sort_key
    )
  end

  sig { returns(T.nilable(Cycle)) }
  def cycle
    return @cycle if defined?(@cycle)
    return @cycle = nil if cycle_name == "all"
    # Cycle requires a collective; for tenant-wide search, skip cycle filtering
    return @cycle = nil if @collective.nil?

    @cycle = Cycle.new(
      name: cycle_name,
      tenant: @tenant,
      collective: T.must(@collective),
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

  sig { params(handles: T::Array[String]).returns(T::Array[String]) }
  def find_user_ids_by_handles(handles)
    return [] if handles.blank?

    @tenant.tenant_users
      .where(handle: handles)
      .pluck(:user_id)
  end

  sig { params(row: SearchIndex).returns(T.untyped) }
  def extract_group_key(row)
    case group_by
    when "item_type"
      row.item_type
    when "status"
      row.status
    when "collective"
      row.collective
    when "creator"
      row.created_by
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

  sig { returns(T::Array[T.untyped]) }
  def group_order
    case group_by
    when "item_type"
      ["Note", "Decision", "Commitment"]
    when "status"
      ["open", "closed"]
    else
      # For collective, creator, and date/time-based groupings, return keys in order of first appearance
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
