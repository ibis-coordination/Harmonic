# typed: false

class UserListsController < ApplicationController
  before_action :set_list, only: [
    :show, :actions_index_show,
    :describe_update_user_list, :execute_update_user_list,
    :describe_delete_user_list, :execute_delete_user_list,
  ]
  before_action :set_owner_for_index, only: [:index]

  # GET /u/:handle/lists — lists owned by this user that the viewer can see.
  def index
    @page_title = "Lists by #{@owner.display_name}"
    @sidebar_mode = "minimal"
    @lists = visible_lists_owned_by(@owner)

    respond_to do |format|
      format.md
    end
  end

  def show
    @page_title = @list.name
    @sidebar_mode = "minimal"
    respond_to do |format|
      format.md
    end
  end

  # ---- actions_index ----

  def actions_index_new
    @page_title = "Actions | Lists"
    render_actions_index(ActionsHelper.actions_for_route("/lists"))
  end

  def actions_index_show
    @page_title = "Actions | #{@list.name}"
    route_info = ActionsHelper.actions_for_route("/lists/:list_id")
    context = { resource: @list, collective: @list.collective }
    actions = (route_info&.dig(:actions) || []).select do |a|
      ActionAuthorization.authorized?(a[:name], @current_user, context)
    end
    render_actions_index({ actions: actions })
  end

  # ---- create_user_list ----

  def describe_create_user_list
    render_action_description(ActionsHelper.action_description("create_user_list"))
  end

  def execute_create_user_list
    name        = params[:name].to_s.strip
    description = params[:description].presence
    visibility  = params[:visibility].presence || "public"

    list = UserList.new(
      creator: @current_user, owner: @current_user,
      tenant: @current_tenant, collective: @current_tenant.main_collective,
      name: name, description: description, visibility: visibility,
      is_primary: false
    )

    if list.save
      render_action_success({
                              action_name: "create_user_list",
                              resource: list,
                              result: "List '#{list.name}' created.",
                            })
    else
      render_action_error({
                            action_name: "create_user_list",
                            error: list.errors.full_messages.join(", "),
                          })
    end
  end

  # ---- update_user_list ----

  def describe_update_user_list
    render_action_description(ActionsHelper.action_description("update_user_list", resource: @list))
  end

  def execute_update_user_list
    return render_owner_only_error("update_user_list") unless @list.owner_id == @current_user.id

    attrs = {}
    attrs[:name]        = params[:name].to_s.strip       if params.key?(:name)
    attrs[:description] = params[:description].presence  if params.key?(:description)
    attrs[:visibility]  = params[:visibility]            if params.key?(:visibility)

    if @list.update(attrs)
      render_action_success({
                              action_name: "update_user_list",
                              resource: @list,
                              result: "List updated.",
                            })
    else
      render_action_error({
                            action_name: "update_user_list",
                            resource: @list,
                            error: @list.errors.full_messages.join(", "),
                          })
    end
  end

  # ---- delete_user_list ----

  def describe_delete_user_list
    render_action_description(ActionsHelper.action_description("delete_user_list", resource: @list))
  end

  def execute_delete_user_list
    return render_owner_only_error("delete_user_list") unless @list.owner_id == @current_user.id

    if @list.is_primary
      return render_action_error({
                                   action_name: "delete_user_list",
                                   resource: @list,
                                   error: "Your list cannot be deleted.",
                                 })
    end

    @list.soft_delete!(by: @current_user)
    render_action_success({
                            action_name: "delete_user_list",
                            resource: @list,
                            result: "List deleted.",
                          })
  end

  private

  # Existence-hiding: a private list the viewer can't see is indistinguishable
  # from a non-existent one. Lookup unscopes the collective filter so a list
  # in any of the tenant's collectives resolves.
  def set_list
    list = UserList
      .tenant_scoped_only(@current_tenant.id)
      .where(deleted_at: nil)
      .find_by(truncated_id: params[:list_id])

    if list.nil? || !list.visible_to?(@current_user)
      render "shared/404", status: :not_found
      return
    end
    @list = list
  end

  def set_owner_for_index
    tu = @current_tenant.tenant_users.find_by(handle: params[:handle])
    return render "shared/404", status: :not_found if tu.nil?

    @owner = tu.user
    @owner.tenant_user = tu
  end

  # Returns the lists owned by `owner` that the current viewer can see, with
  # members preloaded for size display. Visibility is enforced in SQL —
  # `visible_to?` per-row would N+1 on CollectiveMember lookups.
  def visible_lists_owned_by(owner)
    base = UserList
      .tenant_scoped_only(@current_tenant.id)
      .where(owner_id: owner.id, deleted_at: nil)
      .includes(:user_list_members, :members, :collective)
      .order(is_primary: :desc, created_at: :asc)

    return base.to_a if @current_user && @current_user.id == owner.id

    if @current_user.nil?
      coll_ids = []
    else
      coll_ids = CollectiveMember
        .where(user_id: @current_user.id)
        .joins(:collective).where(collectives: { tenant_id: @current_tenant.id })
        .pluck(:collective_id)
    end

    base.where(visibility: "public", collective_id: coll_ids).to_a
  end

  def render_owner_only_error(action_name)
    render_action_error({
                          action_name: action_name,
                          resource: @list,
                          error: "Only the list owner can do this.",
                          status: :forbidden,
                        })
  end
end
