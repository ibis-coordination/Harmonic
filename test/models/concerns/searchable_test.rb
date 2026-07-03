# typed: false

require "test_helper"

class SearchableTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tenant, @collective, @user = create_tenant_collective_user
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
  end

  def index_row_for(note)
    SearchIndex.tenant_scoped_only(@tenant.id).find_by(item_type: "Note", item_id: note.id)
  end

  test "creating an item indexes it synchronously" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user, text: "sync indexed on create")

    row = index_row_for(note)
    assert row, "expected a SearchIndex row at create time, before any job runs"
    assert_includes row.searchable_text, "sync indexed on create"
  end

  test "creating an item does not also enqueue a redundant reindex job" do
    # Decisions and commitments create no invalidating side-records (a
    # Note's author read-confirmation legitimately enqueues one — joining
    # a commitment is a separate explicit action), so Searchable's own
    # create path must be the only indexer — and it runs synchronously.
    assert_no_enqueued_jobs(only: ReindexSearchJob) do
      create_decision(tenant: @tenant, collective: @collective, created_by: @user)
      create_commitment(tenant: @tenant, collective: @collective, created_by: @user)
    end
  end

  test "commitments index synchronously on create" do
    commitment = create_commitment(tenant: @tenant, collective: @collective, created_by: @user, title: "Sync commitment")
    row = SearchIndex.tenant_scoped_only(@tenant.id).find_by(item_type: "Commitment", item_id: commitment.id)
    assert row
    assert_includes row.searchable_text, "Sync commitment"
  end

  test "updates reindex asynchronously" do
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user, text: "original text here")
    clear_enqueued_jobs

    assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Note", item_id: note.id, tenant_id: @tenant.id }]) do
      note.update!(text: "edited text here")
    end
    # The row stays stale until the job runs — updates are eventual.
    assert_includes index_row_for(note).searchable_text, "original text here"
  end

  test "a failing synchronous index write does not block creation" do
    note = nil
    SearchIndexer.stub(:reindex, ->(_item) { raise "index down" }) do
      assert_nothing_raised do
        note = create_note(tenant: @tenant, collective: @collective, created_by: @user, text: "still created")
      end
    end

    assert note.persisted?
    # Falls back to the async job so the item is eventually indexed.
    assert_enqueued_with(job: ReindexSearchJob, args: [{ item_type: "Note", item_id: note.id, tenant_id: @tenant.id }])
  end
end
