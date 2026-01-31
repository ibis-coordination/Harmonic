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
      params: search_params.to_h
    )

    @results = @search.paginated_results
    @grouped_results = @search.grouped_results
    @total_count = @search.total_count
    @next_cursor = @search.next_cursor

    # Track offset for display purposes (separate from pagination logic)
    @offset = (params[:offset].presence || 0).to_i
    @start_position = @offset + 1
    @end_position = @offset + @results.size
    @next_offset = @offset + @results.size

    # Set current_path to include query string for markdown frontmatter
    @current_path = params[:q].present? ? "/search?q=#{ERB::Util.url_encode(params[:q])}" : "/search"

    respond_to do |format|
      format.html
      format.md
      format.json { render json: search_json }
    end
  end

  def actions_index
    @page_title = "Search Actions"
    @sidebar_mode = "minimal"
    render_actions_index(ActionsHelper.actions_for_route("/search"))
  end

  def describe_search
    @page_title = "Search Action"
    @sidebar_mode = "minimal"
    render_action_description(ActionsHelper.action_description("search", resource: nil))
  end

  def execute_search
    query = params[:q].to_s

    respond_to do |format|
      format.html { redirect_to "/search?q=#{ERB::Util.url_encode(query)}" }
      format.md { redirect_to "/search?q=#{ERB::Util.url_encode(query)}" }
      format.json { redirect_to "/search.json?q=#{ERB::Util.url_encode(query)}" }
    end
  end

  private

  def search_params
    permitted = params.permit(:type, :cycle, :filters, :sort_by, :group_by, :cursor, :per_page, :offset)
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
