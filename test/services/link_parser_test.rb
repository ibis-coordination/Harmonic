require "test_helper"

class LinkParserTest < ActiveSupport::TestCase
  def setup
    @tenant = @global_tenant
    @collective = @global_collective
    @user = @global_user
    # Set thread context for operations
    Tenant.scope_thread_to_tenant(subdomain: @tenant.subdomain)
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  # === Class Method parse Tests ===

  test "parse extracts note links from text" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    text = "Check out https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/n/#{note.truncated_id} for details."

    found_records = []
    LinkParser.parse(text, subdomain: @tenant.subdomain, collective_handle: @collective.handle) do |record|
      found_records << record
    end

    assert_equal 1, found_records.length
    assert_equal note.id, found_records.first.id
  end

  test "parse extracts decision links from text" do
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)
    text = "Vote here: https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/d/#{decision.truncated_id}"

    found_records = []
    LinkParser.parse(text, subdomain: @tenant.subdomain, collective_handle: @collective.handle) do |record|
      found_records << record
    end

    assert_equal 1, found_records.length
    assert_equal decision.id, found_records.first.id
  end

  test "parse extracts commitment links from text" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user)
    text = "Join us: https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/c/#{commitment.truncated_id}"

    found_records = []
    LinkParser.parse(text, subdomain: @tenant.subdomain, collective_handle: @collective.handle) do |record|
      found_records << record
    end

    assert_equal 1, found_records.length
    assert_equal commitment.id, found_records.first.id
  end

  test "parse extracts multiple links from text" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)

    text = <<~TEXT
      Check the note: https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/n/#{note.truncated_id}
      And vote here: https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/d/#{decision.truncated_id}
    TEXT

    found_records = []
    LinkParser.parse(text, subdomain: @tenant.subdomain, collective_handle: @collective.handle) do |record|
      found_records << record
    end

    assert_equal 2, found_records.length
    assert_includes found_records.map(&:id), note.id
    assert_includes found_records.map(&:id), decision.id
  end

  test "parse does not duplicate records when same link appears multiple times" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    link = "https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/n/#{note.truncated_id}"
    text = "First: #{link}\nSecond: #{link}\nThird: #{link}"

    found_records = []
    LinkParser.parse(text, subdomain: @tenant.subdomain, collective_handle: @collective.handle) do |record|
      found_records << record
    end

    assert_equal 1, found_records.length
  end

  test "parse ignores links from different subdomains" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    text = "Check out https://other-tenant.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/n/#{note.truncated_id}"

    found_records = []
    LinkParser.parse(text, subdomain: @tenant.subdomain, collective_handle: @collective.handle) do |record|
      found_records << record
    end

    assert_equal 0, found_records.length
  end

  test "parse ignores links from different studios" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    text = "Check out https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/other-studio/n/#{note.truncated_id}"

    found_records = []
    LinkParser.parse(text, subdomain: @tenant.subdomain, collective_handle: @collective.handle) do |record|
      found_records << record
    end

    assert_equal 0, found_records.length
  end

  test "parse handles full UUIDs" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    text = "Check out https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/n/#{note.id}"

    found_records = []
    LinkParser.parse(text, subdomain: @tenant.subdomain, collective_handle: @collective.handle) do |record|
      found_records << record
    end

    assert_equal 1, found_records.length
    assert_equal note.id, found_records.first.id
  end

  test "parse returns empty for text with no links" do
    text = "This is plain text with no links."

    found_records = []
    LinkParser.parse(text, subdomain: @tenant.subdomain, collective_handle: @collective.handle) do |record|
      found_records << record
    end

    assert_equal 0, found_records.length
  end

  test "parse extracts links from markdown with path-only URLs" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    text = "Check out [this note](/studios/#{@collective.handle}/n/#{note.truncated_id}) for details."

    found_records = []
    LinkParser.parse(text, subdomain: @tenant.subdomain, collective_handle: @collective.handle) do |record|
      found_records << record
    end

    assert_equal 1, found_records.length
    assert_equal note.id, found_records.first.id
  end

  test "parse extracts multiple links mixing full URLs and path-only markdown" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    decision = create_decision(tenant: @tenant, collective: @collective, created_by: @user)

    text = <<~TEXT
      Full URL: https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/n/#{note.truncated_id}
      Path-only: [vote here](/studios/#{@collective.handle}/d/#{decision.truncated_id})
    TEXT

    found_records = []
    LinkParser.parse(text, subdomain: @tenant.subdomain, collective_handle: @collective.handle) do |record|
      found_records << record
    end

    assert_equal 2, found_records.length
    assert_includes found_records.map(&:id), note.id
    assert_includes found_records.map(&:id), decision.id
  end

  test "parse handles path-only markdown links with scenes prefix" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    text = "See [the note](/scenes/#{@collective.handle}/n/#{note.truncated_id})"

    found_records = []
    LinkParser.parse(text, subdomain: @tenant.subdomain, collective_handle: @collective.handle) do |record|
      found_records << record
    end

    assert_equal 1, found_records.length
    assert_equal note.id, found_records.first.id
  end

  test "parse handles scene URLs" do
    # Scene URLs follow the pattern /scenes/handle/...
    # The LinkParser regex handles both /studios/ and /scenes/
    # Test with an existing note but using a scenes/ URL pattern
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)

    # Manually construct URL with scenes instead of studios
    text = "Check https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/scenes/#{@collective.handle}/n/#{note.truncated_id}"

    found_records = []
    LinkParser.parse(text, subdomain: @tenant.subdomain, collective_handle: @collective.handle) do |record|
      found_records << record
    end

    # Should find the note since the regex allows both studios and scenes paths
    assert_equal 1, found_records.length
    assert_equal note.id, found_records.first.id
  end

  # === Class Method parse_path Tests ===

  test "parse_path extracts record from path" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    path = "/studios/#{@collective.handle}/n/#{note.truncated_id}"

    record = LinkParser.parse_path(path)
    assert_equal note.id, record.id
  end

  test "parse_path returns nil for invalid path" do
    record = LinkParser.parse_path("/studios/#{@collective.handle}/n/nonexistent-id")
    assert_nil record
  end

  test "parse_path handles full UUID" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    path = "/studios/#{@collective.handle}/n/#{note.id}"

    record = LinkParser.parse_path(path)
    assert_equal note.id, record.id
  end

  # === Instance Initialization Tests ===

  test "can be initialized with from_record" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    parser = LinkParser.new(from_record: note)
    assert_not_nil parser
  end

  test "can be initialized with subdomain and studio_handle" do
    parser = LinkParser.new(subdomain: @tenant.subdomain, collective_handle: @collective.handle)
    assert_not_nil parser
  end

  test "raises error when neither from_record nor subdomain provided" do
    assert_raises ArgumentError do
      LinkParser.new
    end
  end

  test "raises error when only subdomain provided without studio_handle" do
    assert_raises ArgumentError do
      LinkParser.new(subdomain: @tenant.subdomain)
    end
  end

  test "raises error when both from_record and subdomain provided" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    assert_raises ArgumentError do
      LinkParser.new(from_record: note, subdomain: @tenant.subdomain)
    end
  end

  # === Instance parse Method Tests ===

  test "instance parse extracts links from record text" do
    note1 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Note 1", text: "First note")
    note2 = create_note(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      title: "Note 2",
      text: "References https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/n/#{note1.truncated_id}"
    )

    parser = LinkParser.new(from_record: note2)

    found_records = []
    parser.parse do |record|
      found_records << record
    end

    assert_equal 1, found_records.length
    assert_equal note1.id, found_records.first.id
  end

  test "instance parse raises error when text provided with from_record" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    parser = LinkParser.new(from_record: note)

    assert_raises ArgumentError do
      parser.parse("some text") { |r| }
    end
  end

  test "instance parse raises error when no text provided without from_record" do
    parser = LinkParser.new(subdomain: @tenant.subdomain, collective_handle: @collective.handle)

    assert_raises ArgumentError do
      parser.parse { |r| }
    end
  end

  test "instance parse with subdomain requires text" do
    parser = LinkParser.new(subdomain: @tenant.subdomain, collective_handle: @collective.handle)
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    text = "See https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/n/#{note.truncated_id}"

    found_records = []
    parser.parse(text) do |record|
      found_records << record
    end

    assert_equal 1, found_records.length
  end

  # === parse_and_create_link_records! Tests ===

  test "parse_and_create_link_records creates Link records" do
    note1 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Note 1", text: "First note")
    # Create note2 without any links first
    note2 = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      title: "Note 2",
      text: "No links yet"
    )

    # Now update the text to include a link - Linkable concern will handle it in after_save
    # So we manually call parse_and_create_link_records to test the service directly
    new_text = "References https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/n/#{note1.truncated_id}"
    note2.update_column(:text, new_text)  # bypass callbacks

    parser = LinkParser.new(from_record: note2)

    assert_difference -> { Link.count }, 1 do
      parser.parse_and_create_link_records!
    end

    link = Link.find_by(from_linkable: note2, to_linkable: note1)
    assert_not_nil link
  end

  test "parse_and_create_link_records does not duplicate existing links" do
    note1 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Note 1", text: "First note")
    note2 = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      title: "Note 2",
      text: "References https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/n/#{note1.truncated_id}"
    )

    parser = LinkParser.new(from_record: note2)
    parser.parse_and_create_link_records!

    # Parse again - should not create duplicates
    assert_no_difference -> { Link.count } do
      parser.parse_and_create_link_records!
    end
  end

  test "parse_and_create_link_records removes stale links" do
    note1 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Note 1", text: "First note")
    note2 = Note.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      title: "Note 2",
      text: "References https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/n/#{note1.truncated_id}"
    )

    parser = LinkParser.new(from_record: note2)
    parser.parse_and_create_link_records!
    assert_equal 1, Link.where(from_linkable: note2).count

    # Update text to remove link
    note2.update!(text: "No more references")

    # Parse again - should remove the stale link
    parser2 = LinkParser.new(from_record: note2)
    parser2.parse_and_create_link_records!

    assert_equal 0, Link.where(from_linkable: note2).count
  end

  test "parse_and_create_link_records raises error without from_record" do
    parser = LinkParser.new(subdomain: @tenant.subdomain, collective_handle: @collective.handle)

    assert_raises ArgumentError do
      parser.parse_and_create_link_records!
    end
  end

  # === Decision and Commitment Link Tests ===

  test "parse_and_create_link_records works with decision description" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Reference Note", text: "Content")
    # Create decision without links first, then update description bypassing callbacks
    decision = Decision.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      question: "Should we proceed?",
      description: "Initial description",
      deadline: 1.week.from_now
    )
    new_desc = "See https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/n/#{note.truncated_id}"
    decision.update_column(:description, new_desc)  # bypass callbacks

    parser = LinkParser.new(from_record: decision)

    assert_difference -> { Link.count }, 1 do
      parser.parse_and_create_link_records!
    end

    link = Link.find_by(from_linkable: decision, to_linkable: note)
    assert_not_nil link
  end

  test "parse_and_create_link_records works with commitment description" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Reference Note", text: "Content")
    # Create commitment without links first, then update description bypassing callbacks
    commitment = Commitment.create!(
      tenant: @tenant,
      collective: @collective,
      created_by: @user,
      updated_by: @user,
      title: "Test Commitment",
      description: "Initial description",
      critical_mass: 5,
      deadline: 1.week.from_now
    )
    new_desc = "See https://#{@tenant.subdomain}.#{ENV['HOSTNAME']}/studios/#{@collective.handle}/n/#{note.truncated_id}"
    commitment.update_column(:description, new_desc)  # bypass callbacks

    parser = LinkParser.new(from_record: commitment)

    assert_difference -> { Link.count }, 1 do
      parser.parse_and_create_link_records!
    end

    link = Link.find_by(from_linkable: commitment, to_linkable: note)
    assert_not_nil link
  end
end
