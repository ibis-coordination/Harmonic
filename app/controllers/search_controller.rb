# typed: false

class SearchController < ApplicationController
  def show
    @page_title = "Search"
    @page_query = params[:q].to_s.strip.presence
    @sidebar_mode = "minimal"

    @search = SearchQuery.new(
      tenant: @current_tenant,
      current_user: @current_user,
      raw_query: params[:q],
      params: search_params.to_h
    )

    @results = @search.paginated_results
    @grouped_results = @search.grouped_results
    @total_count = @search.total_count
    @next_cursor = @search.next_cursor
    @people_results = @search.people_results

    # Track offset for display purposes (separate from pagination logic)
    @offset = (params[:offset].presence || 0).to_i
    @start_position = @offset + 1
    @end_position = @offset + @results.size
    @next_offset = @offset + @results.size

    respond_to do |format|
      format.html
      format.md
      format.json { render json: search_json }
    end
  end

  private

  def search_params
    permitted = params.permit(:type, :cycle, :filters, :sort_by, :group_by, :cursor, :per_page, :offset)
    # Default to "all" time window for global search (unlike collective search which defaults to "today")
    permitted[:cycle] ||= "all"
    permitted
  end

  def search_json
    {
      query: @search.to_params,
      total_count: @total_count,
      next_cursor: @next_cursor,
      results: @results.map(&:api_json),
      people: @people_results.map { |u| person_json(u) },
    }
  end

  def person_json(user)
    # `user.tenant_user` is pre-populated by SearchQuery#people_results so
    # this needs no extra query.
    {
      id: user.id,
      handle: user.handle,
      display_name: user.display_name.presence || user.name,
      path: user.path,
    }
  end
end
