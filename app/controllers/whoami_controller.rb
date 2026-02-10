# typed: false

class WhoamiController < ApplicationController
  def index
    @page_title = "Who Am I?"
    @sidebar_mode = "minimal"
    respond_to do |format|
      format.html do
        render inline: page_html, layout: true
      end
      format.md
    end
  end

  def actions_index
    render_actions_index(ActionsHelper.actions_for_route("/whoami"))
  end

  def describe_update_scratchpad
    return render plain: "403 Unauthorized", status: 403 unless current_user&.ai_agent?
    render_action_description(ActionsHelper.action_description("update_scratchpad"))
  end

  def execute_update_scratchpad
    return render plain: "403 Unauthorized", status: 403 unless current_user&.ai_agent?

    content = params[:content].to_s

    if content.length > 10_000
      return render_action_error({
        action_name: "update_scratchpad",
        error: "Scratchpad content exceeds maximum length of 10000 characters",
      })
    end

    current_user.agent_configuration ||= {}
    current_user.agent_configuration["scratchpad"] = content.presence
    current_user.save!

    render_action_success({
      action_name: "update_scratchpad",
      result: "Scratchpad updated successfully.",
    })
  end

  private

  def page_html
    markdown(render_to_string("whoami/index", layout: false, formats: [:md]))
  end

  def markdown(text)
    MarkdownRenderer.render(text, shift_headers: false).html_safe
  end

  def current_resource_model
    User
  end
end
