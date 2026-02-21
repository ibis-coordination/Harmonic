# typed: false

# Helper for building non-persisted model instances for ViewComponent tests.
# Uses real AR classes (satisfying Sorbet runtime type checks) with
# delegated methods overridden via define_singleton_method.
module ComponentTestHelper
  # Build a User instance with display_name, handle, path, and image_url
  # accessible without a TenantUser record.
  def build_user(display_name: "Test User", handle: "testuser", path: nil, image_url: nil, user_type: "human", parent: nil)
    user = User.new(user_type: user_type)
    path ||= "/u/#{handle}"
    user.define_singleton_method(:display_name) { display_name }
    user.define_singleton_method(:handle) { handle }
    user.define_singleton_method(:path) { path }
    user.define_singleton_method(:parent) { parent }
    user.define_singleton_method(:image_url) { image_url }
    user
  end

  # Build a Note instance usable as a comment or resource.
  def build_note(text: "Test note", truncated_id: "abc12345", created_by: nil, created_at: 1.hour.ago, updated_at: nil, **attrs)
    note = Note.new(text: text, truncated_id: truncated_id, created_at: created_at, updated_at: updated_at || created_at, **attrs)
    note.define_singleton_method(:created_by) { created_by } if created_by
    note.define_singleton_method(:path) { "/n/#{truncated_id}" }
    note.define_singleton_method(:shareable_link) { "https://example.com/n/#{truncated_id}" }
    note.define_singleton_method(:confirmed_reads) { 0 }
    note.define_singleton_method(:user_has_read?) { |_user| false }
    note
  end

  # Build a Collective instance usable as a studio.
  def build_collective(name: "My Studio", handle: "my-studio", is_scene: false)
    collective = Collective.new(name: name)
    collective.define_singleton_method(:path) { "/s/#{handle}" }
    collective.define_singleton_method(:is_scene?) { is_scene }
    collective
  end
end
