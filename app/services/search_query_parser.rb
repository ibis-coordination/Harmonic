# typed: true

class SearchQueryParser
  extend T::Sig

  # Cycle pattern components for readability
  CYCLE_NAMED = "today|yesterday|tomorrow".freeze
  CYCLE_WEEK = "this-week|last-week|next-week".freeze
  CYCLE_MONTH = "this-month|last-month|next-month".freeze
  CYCLE_YEAR = "this-year|last-year|next-year".freeze
  CYCLE_RELATIVE = '\\d+-days?-ago|\\d+-weeks?-ago|\\d+-months?-ago|\\d+-years?-ago'.freeze
  CYCLE_PATTERN = /^(#{CYCLE_NAMED}|#{CYCLE_WEEK}|#{CYCLE_MONTH}|#{CYCLE_YEAR}|#{CYCLE_RELATIVE}|all)$/

  # Handle pattern for user filters (with @ prefix)
  HANDLE_PATTERN = /^@[a-zA-Z0-9_-]+$/

  # Superagent handle pattern (alphanumeric with dashes)
  SUPERAGENT_HANDLE_PATTERN = /^[a-zA-Z0-9-]+$/i

  # Date pattern for after:/before: operators
  DATE_PATTERN = /^(\d{4}-\d{2}-\d{2}|[+-]\d+[dwmy])$/

  # Integer pattern for min/max operators
  INTEGER_PATTERN = /^\d+$/

  # Operator definitions: key => { values: [...], pattern: /.../, multi: bool }
  # - values: allowed literal values
  # - pattern: regex for dynamic values (handles, dates, etc.)
  # - multi: whether multiple comma-separated values are allowed
  OPERATORS = T.let({
    # Location scope
    "studio" => { pattern: SUPERAGENT_HANDLE_PATTERN, multi: false },
    "scene" => { pattern: SUPERAGENT_HANDLE_PATTERN, multi: false },

    # User filters
    "creator" => { pattern: HANDLE_PATTERN, multi: true },
    "read-by" => { pattern: HANDLE_PATTERN, multi: true },
    "voter" => { pattern: HANDLE_PATTERN, multi: true },
    "participant" => { pattern: HANDLE_PATTERN, multi: true },
    "mentions" => { pattern: HANDLE_PATTERN, multi: true },
    "replying-to" => { pattern: HANDLE_PATTERN, multi: true },

    # Type filters
    "type" => { values: ["note", "decision", "commitment", "n", "d", "c"], multi: true },
    "subtype" => { values: ["comment"], multi: true },
    "status" => { values: ["open", "closed"], multi: false },

    # Boolean filters
    "critical-mass-achieved" => { values: ["true", "false"], multi: false },

    # Integer filters (min/max)
    "min-links" => { pattern: INTEGER_PATTERN, multi: false },
    "max-links" => { pattern: INTEGER_PATTERN, multi: false },
    "min-backlinks" => { pattern: INTEGER_PATTERN, multi: false },
    "max-backlinks" => { pattern: INTEGER_PATTERN, multi: false },
    "min-comments" => { pattern: INTEGER_PATTERN, multi: false },
    "max-comments" => { pattern: INTEGER_PATTERN, multi: false },
    "min-readers" => { pattern: INTEGER_PATTERN, multi: false },
    "max-readers" => { pattern: INTEGER_PATTERN, multi: false },
    "min-voters" => { pattern: INTEGER_PATTERN, multi: false },
    "max-voters" => { pattern: INTEGER_PATTERN, multi: false },
    "min-participants" => { pattern: INTEGER_PATTERN, multi: false },
    "max-participants" => { pattern: INTEGER_PATTERN, multi: false },

    # Time filters
    "cycle" => { pattern: CYCLE_PATTERN, multi: false },
    "after" => { pattern: DATE_PATTERN, multi: false },
    "before" => { pattern: DATE_PATTERN, multi: false },

    # Display options
    "sort" => { values: ["newest", "oldest", "updated", "deadline", "relevance", "backlinks", "new", "old"], multi: false },
    "group" => { values: ["type", "status", "date", "week", "month", "none"], multi: false },
    "limit" => { pattern: INTEGER_PATTERN, multi: false },
  }.freeze, T::Hash[String, T::Hash[Symbol, T.untyped]])

  # Aliases for short forms
  ALIASES = T.let({
    "type" => { "n" => "note", "d" => "decision", "c" => "commitment" },
    "sort" => { "new" => "newest", "old" => "oldest" },
  }.freeze, T::Hash[String, T::Hash[String, String]])

  # Map DSL sort values to SearchQuery sort_by format
  SORT_MAPPING = T.let({
    "newest" => "created_at-desc",
    "oldest" => "created_at-asc",
    "updated" => "updated_at-desc",
    "deadline" => "deadline-asc",
    "relevance" => "relevance-desc",
    "backlinks" => "backlink_count-desc",
  }.freeze, T::Hash[String, String])

  # Map DSL group values to SearchQuery group_by format
  GROUP_MAPPING = T.let({
    "type" => "item_type",
    "status" => "status",
    "date" => "date_created",
    "week" => "week_created",
    "month" => "month_created",
    "none" => "none",
  }.freeze, T::Hash[String, String])

  # Token struct to track metadata about each token
  class Token < T::Struct
    const :text, String
    const :quoted, T::Boolean, default: false
    const :negated, T::Boolean, default: false
  end

  sig { params(raw_query: T.nilable(String)).void }
  def initialize(raw_query)
    @raw_query = raw_query.to_s.strip
    @tokens = T.let([], T::Array[Token])
    @operators = T.let({}, T::Hash[String, T::Array[String]])
    @negated_operators = T.let({}, T::Hash[String, T::Array[String]])
    # Search terms separated by type for different matching strategies
    @fuzzy_terms = T.let([], T::Array[String])       # Regular trigram matching
    @exact_phrases = T.let([], T::Array[String])     # Quoted phrases - exact substring match
    @excluded_terms = T.let([], T::Array[String])    # Negated terms - must NOT contain
  end

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def parse
    tokenize
    extract_operators
    build_params
  end

  private

  sig { void }
  def tokenize
    return if @raw_query.blank?

    # Split on whitespace, respecting quoted strings
    # Also handle negated quoted strings: -"phrase"
    @tokens = @raw_query.scan(/-?"[^"]*"|\S+/).map do |raw_token|
      # Check for negation prefix (works on both quoted and unquoted tokens)
      negated = raw_token.start_with?("-")
      token_text = negated ? T.must(raw_token[1..]) : raw_token

      # Check if quoted
      quoted = token_text.start_with?('"') && token_text.end_with?('"')
      text = quoted ? T.must(token_text[1..-2]) : token_text

      Token.new(text: text, quoted: quoted, negated: negated)
    end
  end

  sig { void }
  def extract_operators
    @tokens.each do |token|
      text = token.text
      next if text.blank?

      # Check for operator: key:value (only for non-quoted tokens)
      # Support hyphenated operator names like "read-by" or "min-links"
      match_data = token.quoted ? nil : text.match(/^([a-z-]+):(.+)$/i)

      if match_data
        key = T.must(match_data[1]).downcase
        value = match_data[2]

        if valid_operator?(key, T.must(value))
          if token.negated
            @negated_operators[key] ||= []
            T.must(@negated_operators[key]).concat(parse_operator_values(key, T.must(value)))
          else
            @operators[key] ||= []
            T.must(@operators[key]).concat(parse_operator_values(key, T.must(value)))
          end
        else
          # Invalid operator - treat as search text
          add_search_term(text, quoted: token.quoted, negated: token.negated)
        end
      else
        add_search_term(text, quoted: token.quoted, negated: token.negated)
      end
    end
  end

  sig { params(text: String, quoted: T::Boolean, negated: T::Boolean).void }
  def add_search_term(text, quoted:, negated:)
    if negated
      # Negated terms go to excluded list (always exact match)
      @excluded_terms << text
    elsif quoted
      # Quoted terms go to exact phrase list
      @exact_phrases << text
    else
      # Regular terms go to fuzzy list
      @fuzzy_terms << text
    end
  end

  sig { params(key: String, value: String).returns(T::Boolean) }
  def valid_operator?(key, value)
    config = OPERATORS[key]
    return false unless config

    values = value.split(",")
    values.all? { |v| valid_operator_value?(key, v, config) }
  end

  sig { params(_key: String, value: String, config: T::Hash[Symbol, T.untyped]).returns(T::Boolean) }
  def valid_operator_value?(_key, value, config)
    # Check against allowed values
    return true if config[:values]&.include?(value.downcase)

    # Check against pattern
    return true if config[:pattern] && value.match?(config[:pattern])

    false
  end

  sig { params(key: String, value: String).returns(T::Array[String]) }
  def parse_operator_values(key, value)
    config = OPERATORS[key]

    # For non-multi operators, return single expanded value
    return [expand_alias(key, value)] unless config&.dig(:multi)

    # For multi operators, split and expand each value
    values = value.split(",")
    values.map { |v| expand_alias(key, v.strip) }
  end

  sig { params(key: String, value: String).returns(String) }
  def expand_alias(key, value)
    ALIASES.dig(key, value.downcase) || value.downcase
  end

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def build_params
    params = {}

    # Search terms - fuzzy matching (q for backwards compatibility)
    params[:q] = @fuzzy_terms.join(" ").presence

    # Exact phrases - quoted strings requiring exact substring match
    params[:exact_phrases] = @exact_phrases if @exact_phrases.present?

    # Excluded terms - must NOT contain these
    params[:excluded_terms] = @excluded_terms if @excluded_terms.present?

    # Type filter
    params[:type] = build_type_param
    params[:exclude_types] = build_exclude_types_param
    params[:subtypes] = build_subtypes_param
    params[:exclude_subtypes] = build_exclude_subtypes_param

    # Status filter (replaces is:open/is:closed)
    params[:status] = build_status_param

    # User-based filters
    params[:creator_handles] = build_user_filter_param("creator")
    params[:exclude_creator_handles] = build_negated_user_filter_param("creator")
    params[:read_by_handles] = build_user_filter_param("read-by")
    params[:exclude_read_by_handles] = build_negated_user_filter_param("read-by")
    params[:voter_handles] = build_user_filter_param("voter")
    params[:exclude_voter_handles] = build_negated_user_filter_param("voter")
    params[:participant_handles] = build_user_filter_param("participant")
    params[:exclude_participant_handles] = build_negated_user_filter_param("participant")
    params[:mentions_handles] = build_user_filter_param("mentions")
    params[:exclude_mentions_handles] = build_negated_user_filter_param("mentions")
    params[:replying_to_handles] = build_user_filter_param("replying-to")
    params[:exclude_replying_to_handles] = build_negated_user_filter_param("replying-to")

    # Boolean filters
    params[:critical_mass_achieved] = build_boolean_param("critical-mass-achieved")

    # Integer filters (min/max)
    params[:min_links] = build_integer_param("min-links")
    params[:max_links] = build_integer_param("max-links")
    params[:min_backlinks] = build_integer_param("min-backlinks")
    params[:max_backlinks] = build_integer_param("max-backlinks")
    params[:min_comments] = build_integer_param("min-comments")
    params[:max_comments] = build_integer_param("max-comments")
    params[:min_readers] = build_integer_param("min-readers")
    params[:max_readers] = build_integer_param("max-readers")
    params[:min_voters] = build_integer_param("min-voters")
    params[:max_voters] = build_integer_param("max-voters")
    params[:min_participants] = build_integer_param("min-participants")
    params[:max_participants] = build_integer_param("max-participants")

    # Sort
    params[:sort_by] = build_sort_param

    # Group
    params[:group_by] = build_group_param

    # Cycle (only if no explicit dates)
    params[:cycle] = build_cycle_param

    # Explicit dates (override cycle)
    params[:after_date] = build_date_param("after")
    params[:before_date] = build_date_param("before")

    # Limit
    params[:per_page] = build_limit_param

    # Superagent scope (studio: or scene:)
    params[:studio_handle] = build_superagent_param("studio")
    params[:scene_handle] = build_superagent_param("scene")

    params.compact
  end

  sig { returns(T.nilable(String)) }
  def build_type_param
    types = @operators["type"]
    return nil if types.blank?

    types.join(",").presence
  end

  sig { returns(T.nilable(T::Array[String])) }
  def build_exclude_types_param
    # Collect types to exclude (from -type:note)
    negated_types = @negated_operators["type"]
    return nil if negated_types.blank?

    negated_types
  end

  sig { returns(T.nilable(T::Array[String])) }
  def build_subtypes_param
    # Collect subtypes to include (from subtype:comment)
    subtypes = @operators["subtype"]
    return nil if subtypes.blank?

    subtypes
  end

  sig { returns(T.nilable(T::Array[String])) }
  def build_exclude_subtypes_param
    # Collect subtypes to exclude (from -subtype:comment)
    negated_subtypes = @negated_operators["subtype"]
    return nil if negated_subtypes.blank?

    negated_subtypes
  end

  sig { returns(T.nilable(String)) }
  def build_status_param
    status_values = @operators["status"]
    negated_status = @negated_operators["status"]

    # Handle negation: -status:open means status:closed
    if negated_status.present?
      negated_value = negated_status.last
      return negated_value == "open" ? "closed" : "open"
    end

    return nil if status_values.blank?

    # Last value wins
    status_values.last
  end

  sig { params(key: String).returns(T.nilable(T::Array[String])) }
  def build_user_filter_param(key)
    handles = @operators[key]
    return nil if handles.blank?

    # Strip @ prefix from handles
    handles.map { |h| h.delete_prefix("@") }
  end

  sig { params(key: String).returns(T.nilable(T::Array[String])) }
  def build_negated_user_filter_param(key)
    handles = @negated_operators[key]
    return nil if handles.blank?

    # Strip @ prefix from handles
    handles.map { |h| h.delete_prefix("@") }
  end

  sig { params(key: String).returns(T.nilable(T::Boolean)) }
  def build_boolean_param(key)
    values = @operators[key]
    return nil if values.blank?

    # Last value wins
    values.last == "true"
  end

  sig { params(key: String).returns(T.nilable(Integer)) }
  def build_integer_param(key)
    values = @operators[key]
    return nil if values.blank?

    # Last value wins
    T.must(values.last).to_i
  end

  sig { returns(T.nilable(String)) }
  def build_sort_param
    sort_values = @operators["sort"]
    return nil if sort_values.blank?

    # Last value wins
    dsl_value = T.must(sort_values.last)
    SORT_MAPPING[dsl_value]
  end

  sig { returns(T.nilable(String)) }
  def build_group_param
    group_values = @operators["group"]
    return nil if group_values.blank?

    # Last value wins
    dsl_value = T.must(group_values.last)
    GROUP_MAPPING[dsl_value]
  end

  sig { returns(T.nilable(String)) }
  def build_cycle_param
    # If explicit dates are present, don't use cycle
    return nil if @operators["after"].present? || @operators["before"].present?

    cycle_values = @operators["cycle"]
    return nil if cycle_values.blank?

    # Last value wins
    T.must(cycle_values.last)
  end

  sig { params(key: String).returns(T.nilable(String)) }
  def build_date_param(key)
    date_values = @operators[key]
    return nil if date_values.blank?

    # Last value wins
    raw_value = T.must(date_values.last)

    # Parse the date value
    parse_date_value(raw_value)
  end

  sig { params(value: String).returns(T.nilable(String)) }
  def parse_date_value(value)
    # Absolute date: YYYY-MM-DD
    return value if value.match?(/^\d{4}-\d{2}-\d{2}$/)

    # Relative date: +Nd, -Nw, etc.
    match_data = value.match(/^([+-])(\d+)([dwmy])$/)
    return nil unless match_data

    sign = match_data[1]
    amount = match_data[2].to_i
    unit = match_data[3]

    # Compute the actual date
    date = case unit
           when "d" then Time.current + (sign == "+" ? amount.days : -amount.days)
           when "w" then Time.current + (sign == "+" ? amount.weeks : -amount.weeks)
           when "m" then Time.current + (sign == "+" ? amount.months : -amount.months)
           when "y" then Time.current + (sign == "+" ? amount.years : -amount.years)
           else Time.current
           end

    date.to_date.to_s
  end

  sig { returns(T.nilable(Integer)) }
  def build_limit_param
    limit_values = @operators["limit"]
    return nil if limit_values.blank?

    # Last value wins, clamp to 1-100
    value = T.must(limit_values.last).to_i
    value = 1 if value < 1
    value = 100 if value > 100
    value
  end

  sig { params(key: String).returns(T.nilable(String)) }
  def build_superagent_param(key)
    values = @operators[key]
    return nil if values.blank?

    # Last value wins (value is already lowercased by expand_alias)
    T.must(values.last)
  end
end
