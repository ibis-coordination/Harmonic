# typed: false

class DevController < ApplicationController
  # Skip tenant/superagent requirements for dev pages
  skip_before_action :set_current_tenant_from_subdomain, raise: false
  skip_before_action :set_current_superagent_from_path, raise: false
  skip_before_action :require_current_tenant, raise: false

  layout "pulse"

  # Override to prevent ApplicationController from trying to find a Dev model
  def current_resource_model
    nil
  end

  def pulse_components
    @page_title = "Pulse Component Library"
    @sidebar_mode = "none"

    # Dummy data for component examples
    @dummy_user = OpenStruct.new(
      display_name: "Jane Developer",
      username: "janedev",
      handle: "janedev",
      path: "#",
      profile_picture: OpenStruct.new(attached?: false),
      subagent?: false,
      parent: nil
    )

    @dummy_note = OpenStruct.new(
      title: "Example Note Title",
      text: "This is the note content with some **markdown** formatting.",
      path: "#",
      created_at: 2.hours.ago,
      updated_at: 1.hour.ago,
      created_by: @dummy_user,
      updated_by: @dummy_user,
      comment_count: 3,
      attachments: []
    )

    @dummy_decision = OpenStruct.new(
      title: "Should we adopt the new design system?",
      text: "Vote on whether to migrate all pages to Pulse.",
      path: "#",
      created_at: 1.day.ago,
      updated_at: 1.day.ago,
      created_by: @dummy_user,
      updated_by: @dummy_user,
      open?: true,
      options: [
        OpenStruct.new(title: "Yes, migrate everything", vote_count: 5),
        OpenStruct.new(title: "No, keep current design", vote_count: 2),
        OpenStruct.new(title: "Migrate gradually", vote_count: 8),
      ]
    )

    @dummy_commitment = OpenStruct.new(
      title: "Complete component library documentation",
      text: "Document all Pulse components with examples.",
      path: "#",
      created_at: 3.days.ago,
      updated_at: 3.days.ago,
      created_by: @dummy_user,
      updated_by: @dummy_user,
      open?: true,
      critical_mass: 3,
      participant_count: 2
    )
  end
end
