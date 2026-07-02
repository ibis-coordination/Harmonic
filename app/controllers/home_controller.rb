# typed: false

class HomeController < ApplicationController
  before_action :redirect_representing

  def index
    @page_title = 'Home'
    @page_scope = "visibility:public list:tuned_in"
    @sidebar_mode = 'none'
    @hide_breadcrumb = true

    # Main-collective content authored by the people the viewer tunes in
    # to, plus the viewer themselves (so your own writing stays on your
    # own home view — you can't tune in to yourself).
    primary_list = @current_user.primary_user_list_in!(@current_tenant)
    member_ids = primary_list.user_list_members.pluck(:user_id)
    @tuned_in_count = member_ids.size
    # Defense in depth: drop any blocked users from the author scope. The
    # UserBlock after_create callback removes both directions of primary-
    # list memberships at block-time, but pre-existing memberships from
    # before that callback shipped could otherwise leak content here —
    # especially in markdown, which has no render-time block filter.
    author_ids = (member_ids - block_related_user_ids.to_a) << @current_user.id

    # Chronological only. Engagement-based proximity scoring against the
    # full tenant doesn't fit the now-filtered author set; revisit when
    # proximity is refactored to be primary-list-based.
    @feed_items = FeedBuilder.new(
      notes_scope: Note.main_collective_scope(@current_tenant).where(created_by_id: author_ids),
      decisions_scope: Decision.main_collective_scope(@current_tenant).where(created_by_id: author_ids),
      commitments_scope: Commitment.main_collective_scope(@current_tenant).where(created_by_id: author_ids),
      reminder_events_scope: NoteHistoryEvent
        .main_collective_scope(@current_tenant)
        .where(event_type: "reminder")
        .joins(:note).where(notes: { created_by_id: author_ids }),
    ).feed_items
  end

  def subdomains
    @page_title = "Subdomains"
    @sidebar_mode = "minimal"
    @public_tenants = Tenant.all_public_tenants
    @other_tenants = (
      (@current_user.own_tenants + @public_tenants) - [@current_tenant]
    ).uniq.sort_by(&:subdomain)
    respond_to do |format|
      format.html
      format.md
    end
  end

  def about
    @page_title = 'About'
    @sidebar_mode = 'minimal'
  end

  def contact
    @page_title = 'Contact'
    @sidebar_mode = 'minimal'
  end

  def actions_index
    @page_title = 'Actions | Home'
    @sidebar_mode = 'minimal'
    @routes_and_actions = ActionsHelper.routes_and_actions_for_user(@current_user)
    render 'actions'
  end

  def page_not_found
    @sidebar_mode = 'minimal'
    render 'shared/404', status: 404
  end

  private

  def redirect_representing
    if current_representation_session
      return redirect_to "/representing"
    end
  end

end
