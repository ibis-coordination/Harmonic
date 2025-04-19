class TenantUser < ApplicationRecord
  include CanPin
  include HasRoles
  include HasDismissibleNotices
  self.implicit_order_column = "created_at"
  belongs_to :tenant
  belongs_to :user
  before_create :set_defaults

  def set_defaults
    self.handle = self.handle.presence || user.name.parameterize
    self.display_name ||= user.name
    self.settings ||= {}
    self.settings['pinned'] ||= {}
    self.settings['scratchpad'] ||= {}
    self.settings['scratchpad'].merge!(default_scratchpad)
    self.roles ||= []
    self.roles << 'default'
  end

  def user
    @user ||= super
    @user.tenant_user ||= self
    @user
  end

  def archive!
    self.archived_at = Time.current
    save!
  end

  def unarchive!
    self.archived_at = nil
    save!
  end

  def archived?
    self.archived_at.present?
  end

  def path
    "/u/#{handle}"
  end

  def url
    "#{tenant.url}#{path}"
  end

  def confirmed_read_note_events(limit: 10)
    NoteHistoryEvent.where(
      tenant_id: tenant_id,
      user_id: user_id,
      event_type: 'read_confirmation',
    ).includes(:note).order(happened_at: :desc).limit(limit)
  end

  def scratchpad
    settings['scratchpad'] || default_scratchpad
  end

  def scratchpad_text
    settings['scratchpad']['text'] || default_scratchpad_text
  end

  def scratchpad_text=(text)
    settings['scratchpad']['text'] = text
  end

  def scratchpad_links(tenant:, studio:)
    # Parse the text of the scratchpad and return an array of links
    links = []
    LinkParser.parse(scratchpad['text'], subdomain: tenant.subdomain, studio_handle: studio.handle) do |resource|
      links << {
        id: resource.truncated_id,
        url: resource.shareable_link,
        title: resource.title,
        type: resource.class.name,
        resource: resource,
      }
    end
    links
  end

  def default_scratchpad
    {
      'text' => default_scratchpad_text,
      'custom_json' => nil,
    }
  end

  def default_scratchpad_text
    <<~SCRATCH_PAD_TEXT
      # Scratchpad

      Your scratchpad is only visible to you. Use it to jot down ideas, bookmark links, or keep track of anything you need to remember.

      <!--
      You are currently in edit mode.
      Click the 👁️ icon in the upper right to view the rendered markdown with clickable links.
      -->

      ## Special functionality of the scratchpad

      When viewing notes, decisions, and commitments, you can click the [...] button in the upper right corner of the page and select "Append link to scratchpad" to add a link here.

      Then when you create new notes, decisions, and commitments, the links on your scratchpad will be accessible via the 🔗 icon in the upper right corner of the creation form with a copy button for convenience.

      ## Links

      * [My Profile](#{url})

    SCRATCH_PAD_TEXT
  end

end
