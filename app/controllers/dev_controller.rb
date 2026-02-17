# typed: false

class DevController < ApplicationController
  before_action :ensure_development_environment

  # Override to prevent ApplicationController from trying to find a Dev model
  def current_resource_model
    nil
  end

  def pulse_components
    @page_title = "Pulse Component Library"
    @sidebar_mode = "none"
    setup_dummy_data
  end

  private

  def ensure_development_environment
    unless Rails.env.development?
      render plain: "Not Found", status: :not_found
    end
  end

  def setup_dummy_data
    @dummy_user = OpenStruct.new(
      display_name: "Jane Developer",
      username: "janedev",
      handle: "janedev",
      path: "#",
      image: OpenStruct.new(attached?: false),
      image_url: nil,
      ai_agent?: false,
      parent: nil
    )

    @dummy_user2 = OpenStruct.new(
      display_name: "Alex Contributor",
      username: "alexc",
      handle: "alexc",
      path: "#",
      image: OpenStruct.new(attached?: false),
      image_url: nil,
      ai_agent?: false,
      parent: nil
    )

    @dummy_studio = OpenStruct.new(
      display_name: "Design Team",
      handle: "design-team",
      path: "/studios/design-team",
      profile_picture: OpenStruct.new(attached?: false)
    )

    @dummy_note = OpenStruct.new(
      title: "Pulse Design System Migration Plan",
      text: "We're migrating all pages to the new Pulse design system.\n\n## Goals\n\n1. **Consistent visual language** across all pages\n2. **Dark mode support** via CSS variables\n3. **Mobile responsiveness** with clear breakpoints\n\n## Timeline\n\nPhase 1 is complete. We're now working on Phase 2.",
      path: "#",
      created_at: 2.hours.ago,
      updated_at: 1.hour.ago,
      created_by: @dummy_user,
      updated_by: @dummy_user,
      comment_count: 3,
      attachments: [],
      is_comment?: false,
      collective: @dummy_studio
    )

    @dummy_decision = OpenStruct.new(
      title: "Should we adopt the new design system?",
      text: "Vote on whether to migrate all pages to Pulse. This will affect the entire application and requires team buy-in.",
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
      ],
      collective: @dummy_studio
    )

    @dummy_commitment = OpenStruct.new(
      title: "Complete component library documentation",
      text: "We commit to documenting all Pulse components with usage examples and code snippets.",
      path: "#",
      created_at: 3.days.ago,
      updated_at: 3.days.ago,
      created_by: @dummy_user,
      updated_by: @dummy_user,
      open?: true,
      critical_mass: 3,
      participant_count: 2,
      collective: @dummy_studio
    )

    @dummy_comments = [
      OpenStruct.new(
        text: "This looks great! I especially like the dark mode support.",
        created_at: 1.hour.ago,
        created_by: @dummy_user2
      ),
      OpenStruct.new(
        text: "Agreed. When can we start migrating the user pages?",
        created_at: 30.minutes.ago,
        created_by: @dummy_user
      ),
    ]

    @dummy_notifications = [
      OpenStruct.new(
        message: "Alex Contributor commented on your note",
        created_at: 30.minutes.ago,
        read: false,
        path: "#"
      ),
      OpenStruct.new(
        message: "New vote on 'Should we adopt the new design system?'",
        created_at: 2.hours.ago,
        read: false,
        path: "#"
      ),
      OpenStruct.new(
        message: "Jane Developer joined 'Complete component library documentation'",
        created_at: 1.day.ago,
        read: true,
        path: "#"
      ),
    ]
  end

end
