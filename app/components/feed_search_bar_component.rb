# typed: true

# Search bar for feed pages (docs/NAVIGATION_DESIGN.md "The feed search
# bar"). Fixed scope filters render as locked chips OUTSIDE the editable
# input — the scope is a statement of where the page is, not text the user
# owns. The input carries refinements in /search syntax; parse warnings
# (e.g. a known operator with an invalid value) render below the form.
class FeedSearchBarComponent < ViewComponent::Base
  extend T::Sig

  sig do
    params(
      action: String,
      query: T.nilable(String),
      scope_filters: T::Array[String],
      warnings: T::Array[String],
      placeholder: String
    ).void
  end
  def initialize(action:, query: nil, scope_filters: [], warnings: [], placeholder: "Search")
    super()
    @action = action
    @query = query
    @scope_filters = scope_filters
    @warnings = warnings
    @placeholder = placeholder
  end
end
