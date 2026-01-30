# typed: false

class SearchController < ApplicationController
  layout "pulse"

  def show
    @page_title = "Search"
    @sidebar_mode = "minimal"

    @search = SearchQuery.new(
      tenant: @current_tenant,
      current_user: @current_user,
      raw_query: params[:q],
      params: search_params.to_h,
    )

    @results = @search.paginated_results
    @grouped_results = @search.grouped_results
    @total_count = @search.total_count
    @next_cursor = @search.next_cursor

    respond_to do |format|
      format.html
      format.md
      format.json { render json: search_json }
    end
  end

  private

  def search_params
    permitted = params.permit(:type, :cycle, :filters, :sort_by, :group_by, :cursor, :per_page)
    # Default to "all" time window for global search (unlike studio search which defaults to "today")
    permitted[:cycle] ||= "all"
    permitted
  end

  def search_json
    {
      query: @search.to_params,
      total_count: @total_count,
      next_cursor: @next_cursor,
      results: @results.map(&:api_json),
    }
  end
end
