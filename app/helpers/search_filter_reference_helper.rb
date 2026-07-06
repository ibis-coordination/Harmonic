# typed: false
# frozen_string_literal: true

# Single source of truth for the search-operator reference table.
#
# The same operators are documented in two places: the /help/search page
# (rendered as markdown) and the /search page's syntax panel (rendered as
# HTML). Both derive from SECTIONS below so the two can never drift. When
# SearchQueryParser learns a new operator, add it here and both surfaces
# update together.
module SearchFilterReferenceHelper
  # Each section has a title, an ordered list of column keys, the rows
  # (one hash per row, keyed by the column symbols), and an optional
  # description shown above the table. Cell text is markdown — backticks
  # and links render on the help page directly and on the /search page via
  # `markdown_inline`.
  SECTIONS = [
    {
      id: :filtering,
      title: "Filtering",
      columns: %i[operator values example],
      rows: [
        { operator: "`visibility:`", values: "public, shared, private", example: "`visibility:shared`" },
        { operator: "`collective:`", values: "collective handle", example: "`collective:my-team`" },
        { operator: "`list:`", values: "list id, or `mutuals` / `tuned_in` (see [Lists](/help/lists))", example: "`list:mutuals`, `list:tuned_in`, `list:abc12345`" },
        { operator: "`type:`", values: "note, decision, commitment", example: "`type:note`" },
        { operator: "`subtype:`", values: "post, reminder, table, comment, statement, summary, vote, lottery, executive, action, calendar_event, policy", example: "`subtype:reminder`" },
        { operator: "`status:`", values: "open, closed", example: "`status:open`" },
        { operator: "`media:`", values: "image, text-only", example: "`media:image`" },
        { operator: "`creator:`", values: "@handle", example: "`creator:@alice`" },
        { operator: "`read-by:`", values: "@handle", example: "`read-by:@alice`" },
        { operator: "`voter:`", values: "@handle", example: "`voter:@alice`" },
        { operator: "`participant:`", values: "@handle", example: "`participant:@alice`" },
        { operator: "`mentions:`", values: "@handle", example: "`mentions:@bob`" },
        { operator: "`replying-to:`", values: "@handle", example: "`replying-to:@alice`" },
        { operator: "`critical-mass-achieved:`", values: "true, false", example: "`critical-mass-achieved:true`" },
      ],
    },
    {
      id: :numeric,
      title: "Numeric Filters",
      description: "Use `min-` and `max-` prefixes with these fields:",
      columns: %i[field example],
      rows: [
        { field: "`links`", example: "`min-links:3`" },
        { field: "`backlinks`", example: "`min-backlinks:1`" },
        { field: "`comments`", example: "`max-comments:10`" },
        { field: "`readers`", example: "`min-readers:5`" },
        { field: "`voters`", example: "`min-voters:3`" },
        { field: "`participants`", example: "`min-participants:2`" },
      ],
    },
    {
      id: :date,
      title: "Date Filters",
      columns: %i[operator values example],
      rows: [
        { operator: "`cycle:`", values: "today, this-week, last-month, etc.", example: "`cycle:this-week`" },
        { operator: "`after:`", values: "YYYY-MM-DD or relative (-Nd/-Nw/-Nm/-Ny)", example: "`after:-7d`" },
        { operator: "`before:`", values: "YYYY-MM-DD or relative (+Nd/+Nw/+Nm/+Ny)", example: "`before:2026-01-01`" },
      ],
    },
    {
      id: :sorting,
      title: "Sorting and Grouping",
      columns: %i[operator values],
      rows: [
        { operator: "`sort:`", values: "newest, oldest, updated, deadline, relevance" },
        { operator: "`group:`", values: "collective, creator, type, status, date, week, month, none" },
        { operator: "`limit:`", values: "1-100" },
      ],
    },
  ].freeze

  COLUMN_HEADERS = {
    operator: "Operator",
    values: "Values",
    example: "Example",
    field: "Field",
  }.freeze

  def search_filter_reference_section(id)
    section = SECTIONS.find { |s| s[:id] == id.to_sym }
    return "" unless section

    render_search_filter_section_markdown(section)
  end

  # The full reference as HTML, for the /search syntax panel. Each section
  # becomes a small heading + table; cell markdown is rendered inline.
  def search_filter_reference_html
    safe_join(SECTIONS.map { |section| render_search_filter_section_html(section) })
  end

  private

  def render_search_filter_section_markdown(section)
    cols = section[:columns]
    lines = ["### #{section[:title]}", ""]
    if section[:description]
      lines << section[:description]
      lines << ""
    end
    lines << "| #{cols.map { |c| COLUMN_HEADERS[c] }.join(' | ')} |"
    lines << "|#{cols.map { '---' }.join('|')}|"
    section[:rows].each do |row|
      lines << "| #{cols.map { |c| row[c] }.join(' | ')} |"
    end
    lines << ""
    lines.join("\n")
  end

  def render_search_filter_section_html(section)
    cols = section[:columns]
    header = content_tag(:tr, safe_join(cols.map { |c| content_tag(:th, COLUMN_HEADERS[c]) }))
    body = section[:rows].map do |row|
      content_tag(:tr, safe_join(cols.map { |c| content_tag(:td, markdown_inline(row[c].to_s)) }))
    end

    parts = [content_tag(:h4, section[:title], style: "font-size: 0.9rem; margin: 1rem 0 0.25rem;")]
    if section[:description]
      parts << content_tag(:p, markdown_inline(section[:description]),
                           style: "font-size: 0.85rem; color: var(--color-fg-muted); margin-bottom: 0.5rem;")
    end
    parts << content_tag(:table,
                         safe_join([content_tag(:thead, header), content_tag(:tbody, safe_join(body))]),
                         class: "pulse-table", style: "font-size: 0.85rem;")
    safe_join(parts)
  end
end
