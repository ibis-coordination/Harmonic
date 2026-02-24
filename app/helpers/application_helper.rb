# typed: false

module ApplicationHelper
  # Generate consistent avatar initials from a name
  # Returns up to 2 uppercase characters
  def avatar_initials(name)
    return "?" if name.blank?

    parts = name.to_s.split(/[\s\-_]+/)
    if parts.length >= 2
      "#{parts[0][0]}#{parts[1][0]}".upcase
    else
      name[0..1].upcase
    end
  end

  def timeago(datetime)
    ago_or_from_now = datetime < Time.now ? 'ago' : 'from now'
    "<time
      data-controller='timeago'
      data-timeago-datetime-value='#{datetime.to_datetime.iso8601}'
      title='#{datetime.to_s}'
    >#{time_ago_in_words(datetime)} #{ago_or_from_now}</time>".html_safe
  end

  def time_ago_or_from_now(datetime)
    return "" unless datetime
    ago_or_from_now = datetime < Time.now ? 'ago' : 'from now'
    time_ago_in_words(datetime) + " " + ago_or_from_now
  end

  def duration_in_words(duration)
    seconds = duration.to_i
    minutes = seconds / 60
    hours = minutes / 60
    days = hours / 24
    weeks = days / 7
    months = days / 30
    years = days / 365
    significant_unit = if years > 0
      "#{years} year".pluralize(years)
    # elsif months > 0
    #   "#{months} month".pluralize(months)
    elsif weeks > 0
      "#{weeks} week".pluralize(weeks)
    elsif days > 0
      "#{days} day".pluralize(days)
    elsif hours > 0
      "#{hours} hour".pluralize(hours)
    elsif minutes > 0
      "#{minutes} minute".pluralize(minutes)
    else
      "#{seconds} second".pluralize(seconds)
    end
    next_unit = if years > 0
      months = months % 12
      "#{months} month".pluralize(months)
    # elsif months > 0
    #   days = days % 30
    #   "#{days} day".pluralize(days)
    elsif weeks > 0
      days = days % 7
      "#{days} day".pluralize(days)
    elsif days > 0
      hours = hours % 24
      "#{hours} hour".pluralize(hours)
    elsif hours > 0
      minutes = minutes % 60
      "#{minutes} minute".pluralize(minutes)
    else
      seconds = seconds % 60
      "#{seconds} second".pluralize(seconds)
    end
    "#{significant_unit} + #{next_unit}"
  end

  def countdown(datetime, base_unit: 'seconds')
    "<time
      data-controller='countdown'
      data-countdown-end-time-value='#{datetime.iso8601}'
      data-countdown-base-unit-value='#{base_unit}'
      >
      <span data-countdown-target='time' style='font-family:monospace;white-space:nowrap;'>...</span>
    </time>".html_safe
  end

  def markdown(text, shift_headers: true)
    return "" unless text
    MarkdownRenderer.render(text, shift_headers: shift_headers).html_safe
  end

  def markdown_inline(text)
    return "" unless text
    MarkdownRenderer.render_inline(text).html_safe
  end

  # Render a user link in markdown format, with parent attribution for ai_agents
  def user_link_md(user, include_parent: true)
    return "" unless user
    base_link = "[#{user.display_name}](#{user.path})"
    if include_parent && user.ai_agent? && user.parent
      "#{base_link} (ai_agent of [#{user.parent.display_name}](#{user.parent.path}))"
    else
      base_link
    end
  end

  # Delegates to ProfilePicComponent. Existing callers can continue using this helper.
  # New code should use: render ProfilePicComponent.new(user: user, size: 30)
  def profile_pic(user, size: 30, style: "", show_parent: false)
    render ProfilePicComponent.new(user: user, size: size, style: style, show_parent: show_parent)
  end

  # Convert a SearchIndex record to a hash for pulse_resource_link partial
  def search_result_to_hash(search_index)
    {
      type: search_index.item_type,
      path: search_index.path,
      title: search_index.title,
      metric_value: search_index_metric_value(search_index),
      metric_name: search_index_metric_name(search_index),
      octicon_metric_icon_name: search_index_metric_icon(search_index),
    }
  end

  def search_index_metric_value(search_index)
    case search_index.item_type
    when "Note" then search_index.participant_count
    when "Decision" then search_index.voter_count
    when "Commitment" then search_index.participant_count
    end
  end

  def search_index_metric_name(search_index)
    case search_index.item_type
    when "Note" then "readers"
    when "Decision" then "voters"
    when "Commitment" then "participants"
    end
  end

  def search_index_metric_icon(search_index)
    case search_index.item_type
    when "Note" then "book"
    when "Decision" then "check-circle"
    when "Commitment" then "person"
    end
  end

  # Render a rich group header for search results
  # Returns HTML content for collective/creator groupings, or the plain key otherwise
  def search_group_header(group_key)
    case group_key
    when Collective
      search_collective_header(group_key)
    when User
      search_user_header(group_key)
    else
      group_key || "Results"
    end
  end

  def search_collective_header(collective)
    type_label = collective.is_scene? ? "Scene" : "Studio"
    initial = collective.name.to_s.first&.upcase || "?"

    avatar = content_tag(:span, class: "pulse-group-avatar") do
      content_tag(:span, initial, class: "pulse-group-avatar-initials")
    end

    content_tag(:span, class: "pulse-group-header pulse-group-header-collective") do
      safe_join(
        [
          avatar,
          content_tag(:span, "#{type_label}: ", class: "pulse-group-type-label"),
          link_to(collective.name, collective.path, class: "pulse-group-link"),
        ]
      )
    end
  end

  def search_user_header(user)
    initial = user.display_name.to_s.first&.upcase || "?"
    has_image = user.image_url.present? && user.image_url != "/placeholder.png"

    avatar = content_tag(:span, class: "pulse-group-avatar") do
      avatar_content = content_tag(:span, initial, class: "pulse-group-avatar-initials")
      if has_image
        avatar_content += content_tag(:img, nil, src: user.image_url, alt: "", class: "pulse-group-avatar-img")
      end
      avatar_content
    end

    handle_text = user.handle.present? ? " (@#{user.handle})" : ""

    content_tag(:span, class: "pulse-group-header pulse-group-header-user") do
      safe_join(
        [
          avatar,
          link_to("#{user.display_name}#{handle_text}", user.path, class: "pulse-group-link"),
        ]
      )
    end
  end

  # Render a plain text/markdown group header for search results
  def search_group_header_markdown(group_key)
    case group_key
    when Collective
      type_label = group_key.is_scene? ? "Scene" : "Studio"
      "#{type_label}: [#{group_key.name}](#{group_key.path})"
    when User
      handle_text = group_key.handle.present? ? " (@#{group_key.handle})" : ""
      "[#{group_key.display_name}#{handle_text}](#{group_key.path})"
    else
      group_key || "Results"
    end
  end

  # Generate a sort link for the security dashboard, toggling direction if already sorted by this column
  def security_sort_link(column, label)
    current_sort = params[:sort_by] == column || (column == "timestamp" && params[:sort_by].blank?)
    current_dir = params[:sort_dir].presence || "desc"
    new_dir = current_sort && current_dir == "desc" ? "asc" : "desc"

    url_params = request.query_parameters.merge(sort_by: column, sort_dir: new_dir)
    link_to "/admin/security?#{url_params.to_query}" do
      indicator = if current_sort
        octicon(current_dir == "desc" ? "chevron-down" : "chevron-up", height: 12)
      else
        ""
      end
      "#{label} #{indicator}".html_safe
    end
  end

end
