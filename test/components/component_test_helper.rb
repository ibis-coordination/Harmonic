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
  def build_note(text: "Test note", title: nil, truncated_id: "abc12345", created_by: nil, created_at: 1.hour.ago, updated_at: nil,
                 is_comment: false, commentable: nil, **attrs)
    note = Note.new(text: text, title: title, truncated_id: truncated_id, created_at: created_at, updated_at: updated_at || created_at, **attrs)
    note.define_singleton_method(:created_by) { created_by } if created_by
    note.define_singleton_method(:path) { "/n/#{truncated_id}" }
    note.define_singleton_method(:shareable_link) { "https://example.com/n/#{truncated_id}" }
    note.define_singleton_method(:confirmed_reads) { 0 }
    note.define_singleton_method(:user_has_read?) { |_user| false }
    if is_comment && commentable
      note.define_singleton_method(:is_comment?) { true }
      note.define_singleton_method(:commentable) { commentable }
    end
    # Stub representation methods
    note.define_singleton_method(:created_via_representation?) { false }
    note.define_singleton_method(:representative_user) { nil }
    # Stub note_history_events as an empty relation-like object
    empty_scope = NoteHistoryEvent.none
    note.define_singleton_method(:note_history_events) { empty_scope }
    note
  end

  # Build a Decision instance for feed item tests.
  def build_decision(question: "Test question?", description: nil, truncated_id: "dec12345", closed: false, results: [], created_by: nil,
                     created_at: 2.hours.ago)
    deadline = closed ? 1.day.ago : 1.day.from_now
    decision = Decision.new(question: question, description: description, truncated_id: truncated_id, deadline: deadline, created_at: created_at,
                            updated_at: created_at)
    decision.define_singleton_method(:created_by) { created_by } if created_by
    decision.define_singleton_method(:path) { "/d/#{truncated_id}" }
    decision.define_singleton_method(:results) { results }
    decision.define_singleton_method(:created_via_representation?) { false }
    decision.define_singleton_method(:representative_user) { nil }
    decision
  end

  # Build a Commitment instance for feed item tests.
  def build_commitment(title: "Test commitment", description: nil, truncated_id: "com12345", closed: false, participant_count: 0, critical_mass: 5,
                       created_by: nil, created_at: 3.hours.ago)
    deadline = closed ? 1.day.ago : 1.day.from_now
    commitment = Commitment.new(title: title, description: description, truncated_id: truncated_id, deadline: deadline, critical_mass: critical_mass,
                                created_at: created_at, updated_at: created_at)
    commitment.define_singleton_method(:created_by) { created_by } if created_by
    commitment.define_singleton_method(:path) { "/c/#{truncated_id}" }
    commitment.define_singleton_method(:participant_count) { participant_count }
    committed_participants_scope = CommitmentParticipant.none
    commitment.define_singleton_method(:committed_participants) { committed_participants_scope }
    participants_scope = CommitmentParticipant.none
    commitment.define_singleton_method(:participants) { participants_scope }
    commitment.define_singleton_method(:created_via_representation?) { false }
    commitment.define_singleton_method(:representative_user) { nil }
    commitment
  end

  # Build a Collective instance usable as a studio.
  def build_collective(name: "My Studio", handle: "my-studio", is_scene: false)
    collective = Collective.new(name: name)
    collective.define_singleton_method(:path) { "/s/#{handle}" }
    collective.define_singleton_method(:is_scene?) { is_scene }
    collective
  end
end
