# typed: false

class UserListsController < ApplicationController
  before_action :set_list, only: [
    :show, :edit, :actions_index_show,
    :describe_update_user_list, :execute_update_user_list,
    :describe_delete_user_list, :execute_delete_user_list,
    :describe_add_member_to_list, :execute_add_member_to_list,
    :describe_remove_member_from_list, :execute_remove_member_from_list,
    :describe_join_list, :execute_join_list,
  ]
  before_action :set_owner_for_index, only: [:index]

  # GET /u/:handle/lists — lists owned by this user that the viewer can see.
  def index
    @page_title = "Lists by #{@owner.display_name}"
    @sidebar_mode = "minimal"
    @lists = visible_lists_owned_by(@owner)

    respond_to do |format|
      format.html
      format.md
    end
  end

  def show
    @page_title = @list.display_name
    @sidebar_mode = "minimal"
    @active_tab = params[:tab] == "members" ? "members" : "feed"
    # Auto-prefill the global header search with `list:<id>` while we're here.
    @current_list_for_search = @list

    # Preload members + the handles we'll display so the view doesn't N+1
    # on per-member tenant_user lookups. One query for member rows, one
    # query for User records, one query for handles (covering members + owner).
    member_user_ids = @list.user_list_members.pluck(:user_id)
    @members = User.where(id: member_user_ids).to_a
    @handles_by_user_id = TenantUser
      .where(tenant_id: @list.tenant_id, user_id: ([@list.owner_id] + member_user_ids).uniq)
      .pluck(:user_id, :handle)
      .to_h

    # Feed of recent content authored by members of this list, scoped to the
    # tenant's main collective (matching the home-feed shape). Members only
    # — no self-inclusion: a custom list is "these people," not "these
    # people + me." Defense in depth: drop any blocked authors, mirroring
    # the home_controller filter so the markdown view (which has no
    # render-time block filter) can't leak a stale tune-in across a block.
    author_ids = member_user_ids - block_related_user_ids.to_a

    @feed_items = if author_ids.empty?
      []
    else
      FeedBuilder.new(
        notes_scope: Note.main_collective_scope(@current_tenant).where(created_by_id: author_ids),
        decisions_scope: Decision.main_collective_scope(@current_tenant).where(created_by_id: author_ids),
        commitments_scope: Commitment.main_collective_scope(@current_tenant).where(created_by_id: author_ids),
        reminder_events_scope: NoteHistoryEvent
          .main_collective_scope(@current_tenant)
          .where(event_type: "reminder")
          .joins(:note).where(notes: { created_by_id: author_ids }),
      ).feed_items
    end

    respond_to do |format|
      format.html
      format.md
    end
  end

  # GET /lists/new
  def new
    return render "shared/403", status: :forbidden unless @current_user

    @list = UserList.new(visibility: "public", add_policy: "owner_only")
    @page_title = "New List"
    @sidebar_mode = "minimal"
  end

  # GET /lists/:list_id/edit
  def edit
    return render "shared/403", status: :forbidden unless @list.owner_id == @current_user&.id
    return render "shared/403", status: :forbidden if @list.is_primary

    @page_title = "Edit #{@list.display_name}"
    @sidebar_mode = "minimal"
  end

  # ---- actions_index ----

  def actions_index_new
    @page_title = "Actions | Lists"
    render_actions_index(ActionsHelper.actions_for_route("/lists"))
  end

  def actions_index_show
    @page_title = "Actions | #{@list.display_name}"
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
    add_policy  = params[:add_policy].presence || "owner_only"

    list = UserList.new(
      creator: @current_user, owner: @current_user,
      tenant: @current_tenant, collective: @current_tenant.main_collective,
      name: name, description: description, visibility: visibility,
      add_policy: add_policy, is_primary: false
    )

    if list.save
      render_action_success({
                              action_name: "create_user_list",
                              resource: list,
                              result: "List '#{list.name}' created.",
                              redirect_to: list.path,
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

    if @list.is_primary
      return render_action_error({
                                   action_name: "update_user_list",
                                   resource: @list,
                                   error: "The tune-in list cannot be edited.",
                                   status: :forbidden,
                                 })
    end

    attrs = {}
    attrs[:name]        = params[:name].to_s.strip       if params.key?(:name)
    attrs[:description] = params[:description].presence  if params.key?(:description)
    attrs[:visibility]  = params[:visibility]            if params.key?(:visibility)
    attrs[:add_policy]  = params[:add_policy]            if params.key?(:add_policy)

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
    owner_handle = @list.owner.tenant_users.find_by(tenant_id: @list.tenant_id)&.handle
    render_action_success({
                            action_name: "delete_user_list",
                            resource: @list,
                            result: "List deleted.",
                            redirect_to: owner_handle ? "/u/#{owner_handle}/lists" : "/",
                          })
  end

  # ---- add_member_to_list ----

  def describe_add_member_to_list
    render_action_description(ActionsHelper.action_description("add_member_to_list", resource: @list))
  end

  def execute_add_member_to_list
    target = resolve_target_user(params[:user_handle])
    return render_action_error({
                                 action_name: "add_member_to_list",
                                 resource: @list,
                                 error: "User not found.",
                               }) if target.nil?

    unless @list.can_add?(actor: @current_user, target: target)
      return render_action_error({
                                   action_name: "add_member_to_list",
                                   resource: @list,
                                   error: "You are not permitted to add members to this list.",
                                   status: :forbidden,
                                 })
    end

    membership = @list.user_list_members.find_or_initialize_by(user_id: target.id)
    if membership.persisted?
      return render_action_success({
                                     action_name: "add_member_to_list",
                                     resource: @list,
                                     result: "Already on this list.",
                                   })
    end

    membership.added_by = @current_user
    if membership.save
      render_action_success({
                              action_name: "add_member_to_list",
                              resource: @list,
                              result: "Added.",
                            })
    else
      render_action_error({
                            action_name: "add_member_to_list",
                            resource: @list,
                            error: membership.errors.full_messages.join(", "),
                          })
    end
  end

  # ---- remove_member_from_list (fixed rule: owner OR self) ----

  def describe_remove_member_from_list
    render_action_description(ActionsHelper.action_description("remove_member_from_list", resource: @list))
  end

  def execute_remove_member_from_list
    target = resolve_target_user(params[:user_handle])
    return render_action_error({
                                 action_name: "remove_member_from_list",
                                 resource: @list,
                                 error: "User not found.",
                               }) if target.nil?

    is_owner = @list.owner_id == @current_user.id
    is_self  = target.id == @current_user.id
    unless is_owner || is_self
      return render_action_error({
                                   action_name: "remove_member_from_list",
                                   resource: @list,
                                   error: "You can only remove yourself, or the owner can remove anyone.",
                                   status: :forbidden,
                                 })
    end

    membership = @list.user_list_members.find_by(user_id: target.id)
    if membership.nil?
      return render_action_success({
                                     action_name: "remove_member_from_list",
                                     resource: @list,
                                     result: "Not on this list.",
                                   })
    end

    membership.destroy!
    render_action_success({
                            action_name: "remove_member_from_list",
                            resource: @list,
                            result: "Removed.",
                          })
  end

  # ---- join (markdown self-join — same effect as add_member_to_list with own handle) ----

  def describe_join_list
    render_action_description(ActionsHelper.action_description("join_list", resource: @list))
  end

  def execute_join_list
    unless @list.can_add?(actor: @current_user, target: @current_user)
      return render_action_error({
                                   action_name: "join_list",
                                   resource: @list,
                                   error: "This list's add policy doesn't allow you to join.",
                                   status: :forbidden,
                                 })
    end

    membership = @list.user_list_members.find_or_initialize_by(user_id: @current_user.id)
    if membership.persisted?
      return render_action_success({
                                     action_name: "join_list",
                                     resource: @list,
                                     result: "Already on this list.",
                                   })
    end

    membership.added_by = @current_user
    if membership.save
      render_action_success({
                              action_name: "join_list",
                              resource: @list,
                              result: "Joined.",
                            })
    else
      render_action_error({
                            action_name: "join_list",
                            resource: @list,
                            error: membership.errors.full_messages.join(", "),
                          })
    end
  end

  private

  def resolve_target_user(handle)
    return nil if handle.blank?
    tu = @current_tenant.tenant_users.find_by(handle: handle.to_s.delete_prefix("@"))
    tu&.user
  end

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
