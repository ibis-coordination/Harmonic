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

  # Operator definitions: key => { values: [...], pattern: /.../, multi: bool }
  # - values: allowed literal values
  # - pattern: regex for dynamic values (handles, dates, etc.)
  # - multi: whether multiple comma-separated values are allowed
  OPERATORS = T.let({
    "type" => { values: ["note", "decision", "commitment", "n", "d", "c"], multi: true },
    "is" => { values: ["open", "closed", "mine", "pinned"], multi: true },
    "has" => { values: ["backlinks", "links", "participants", "comments"], multi: true },
    "by" => { pattern: /^(@\w+|me)$/, multi: true },
    "sort" => { values: ["newest", "oldest", "updated", "deadline", "relevance", "backlinks", "new", "old"], multi: false },
    "group" => { values: ["type", "status", "date", "week", "month", "none"], multi: false },
    "cycle" => { pattern: CYCLE_PATTERN, multi: false },
    "after" => { pattern: /^(\d{4}-\d{2}-\d{2}|[+-]\d+[dwmy])$/, multi: false },
    "before" => { pattern: /^(\d{4}-\d{2}-\d{2}|[+-]\d+[dwmy])$/, multi: false },
    "limit" => { pattern: /^\d+$/, multi: false },
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
      match_data = token.quoted ? nil : text.match(/^(\w+):(.+)$/)

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

    # Filters (is:, has:, by:)
    params[:filters] = build_filters_param

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

    params.compact
  end

  sig { returns(T.nilable(String)) }
  def build_type_param
    types = @operators["type"]
    return nil if types.blank?

    # Exclude negated types
    negated = @negated_operators["type"] || []
    filtered = types - negated

    filtered.join(",").presence
  end

  sig { returns(T.nilable(String)) }
  def build_filters_param
    filters = []

    # is: filters
    (@operators["is"] || []).each do |value|
      case value
      when "mine" then filters << "mine"
      when "open" then filters << "open"
      when "closed" then filters << "closed"
      when "pinned" then filters << "pinned"
      end
    end

    # Negated is: filters
    (@negated_operators["is"] || []).each do |value|
      case value
      when "mine" then filters << "not_mine"
      when "open" then filters << "closed"
      when "closed" then filters << "open"
      end
    end

    # has: filters
    (@operators["has"] || []).each do |value|
      filters << "has_#{value}"
    end

    # Negated has: filters (not implemented yet, but structure is ready)

    # by: filters
    (@operators["by"] || []).each do |value|
      if value == "me"
        filters << "mine"
      else
        # Strip @ from handle
        handle = value.delete_prefix("@")
        filters << "created_by:#{handle}"
      end
    end

    filters.join(",").presence
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
end
