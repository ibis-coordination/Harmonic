# typed: false
# frozen_string_literal: true

require "test_helper"

# Tests for tenant context management in jobs.
# These tests verify that:
# 1. ApplicationJob clears/restores context properly via around_perform
# 2. TenantScopedJob provides correct context helpers
# 3. SystemJob validates absence of tenant context
class JobTenantContextTest < ActiveJob::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
  end

  def teardown
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
    AiAgentTaskRun.clear_thread_scope
  end

  # -----------------------------------
  # ApplicationJob Context Management Tests
  # -----------------------------------

  test "ApplicationJob clears context before job execution" do
    # Set context before enqueuing job
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    context_in_job = nil

    # Create a job that captures context
    job_class = Class.new(TenantScopedJob) do
      define_method(:perform) do
        context_in_job = {
          tenant_id: Tenant.current_id,
          collective_id: Collective.current_id,
        }
      end
    end

    # Run the job (around_perform will clear context first)
    job_class.perform_now

    # Context should be nil inside the job (around_perform cleared it)
    assert_nil context_in_job[:tenant_id], "Tenant context should be cleared"
    assert_nil context_in_job[:collective_id], "Collective context should be cleared"
  end

  test "ApplicationJob restores context after job execution for inline jobs" do
    # Set context before job
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)

    original_tenant_id = Tenant.current_id
    original_collective_id = Collective.current_id

    # Run a job that modifies context
    job_class = Class.new(TenantScopedJob) do
      define_method(:perform) do
        # This would normally modify context in a real job
      end
    end

    job_class.perform_now

    # Context should be restored after job completes
    assert_equal original_tenant_id, Tenant.current_id, "Tenant context should be restored"
    assert_equal original_collective_id, Collective.current_id, "Collective context should be restored"
  end

  # -----------------------------------
  # TenantScopedJob Tests
  # -----------------------------------

  test "set_tenant_context! sets all tenant thread variables" do
    context_after_set = nil

    job_class = Class.new(TenantScopedJob) do
      attr_accessor :tenant_to_set

      define_method(:perform) do
        set_tenant_context!(tenant_to_set)
        context_after_set = {
          tenant_id: Tenant.current_id,
          subdomain: Tenant.current_subdomain,
          main_collective_id: Tenant.current_main_collective_id,
        }
      end
    end

    job = job_class.new
    job.tenant_to_set = @tenant
    job.perform_now

    assert_equal @tenant.id, context_after_set[:tenant_id]
    assert_equal @tenant.subdomain, context_after_set[:subdomain]
    assert_equal @tenant.main_collective_id, context_after_set[:main_collective_id]
  end

  test "set_collective_context! sets collective thread variables" do
    context_after_set = nil

    job_class = Class.new(TenantScopedJob) do
      attr_accessor :tenant_to_set, :collective_to_set

      define_method(:perform) do
        set_tenant_context!(tenant_to_set)
        set_collective_context!(collective_to_set)
        context_after_set = {
          collective_id: Collective.current_id,
          collective_handle: Collective.current_handle,
        }
      end
    end

    job = job_class.new
    job.tenant_to_set = @tenant
    job.collective_to_set = @collective
    job.perform_now

    assert_equal @collective.id, context_after_set[:collective_id]
    assert_equal @collective.handle, context_after_set[:collective_handle]
  end

  test "require_tenant_context! raises when context not set" do
    job_class = Class.new(TenantScopedJob) do
      define_method(:perform) do
        require_tenant_context!
      end
    end

    error = assert_raises(TenantScopedJob::MissingTenantContextError) do
      job_class.perform_now
    end

    assert_match(/requires tenant context/, error.message)
  end

  test "require_tenant_context! passes when context is set" do
    job_class = Class.new(TenantScopedJob) do
      attr_accessor :tenant_to_set

      define_method(:perform) do
        set_tenant_context!(tenant_to_set)
        require_tenant_context!
      end
    end

    job = job_class.new
    job.tenant_to_set = @tenant

    # Should not raise
    assert_nothing_raised { job.perform_now }
  end

  test "tenant_context_set? returns correct boolean" do
    results = []

    job_class = Class.new(TenantScopedJob) do
      attr_accessor :tenant_to_set

      define_method(:perform) do
        results << tenant_context_set?
        set_tenant_context!(tenant_to_set)
        results << tenant_context_set?
      end
    end

    job = job_class.new
    job.tenant_to_set = @tenant
    job.perform_now

    assert_equal [false, true], results
  end

  # -----------------------------------
  # SystemJob Tests
  # -----------------------------------

  test "SystemJob runs successfully without tenant context" do
    executed = false

    job_class = Class.new(SystemJob) do
      define_method(:perform) do
        executed = true
      end
    end

    assert_nothing_raised { job_class.perform_now }
    assert executed, "Job should have executed"
  end

  test "with_tenant_context temporarily sets and clears context" do
    tenant = @tenant
    contexts = []

    job_class = Class.new(SystemJob) do
      attr_accessor :tenant_to_use

      define_method(:perform) do
        contexts << Tenant.current_id
        with_tenant_context(tenant_to_use) do
          contexts << Tenant.current_id
        end
        contexts << Tenant.current_id
      end
    end

    job = job_class.new
    job.tenant_to_use = tenant
    job.perform_now

    assert_nil contexts[0], "Context should be nil before with_tenant_context"
    assert_equal tenant.id, contexts[1], "Context should be set inside block"
    assert_nil contexts[2], "Context should be cleared after block"
  end

  test "with_tenant_and_collective_context sets both contexts" do
    tenant = @tenant
    collective = @collective
    contexts = []

    job_class = Class.new(SystemJob) do
      attr_accessor :tenant_to_use, :collective_to_use

      define_method(:perform) do
        with_tenant_and_collective_context(tenant_to_use, collective_to_use) do
          contexts << {
            tenant_id: Tenant.current_id,
            collective_id: Collective.current_id,
          }
        end
        contexts << {
          tenant_id: Tenant.current_id,
          collective_id: Collective.current_id,
        }
      end
    end

    job = job_class.new
    job.tenant_to_use = tenant
    job.collective_to_use = collective
    job.perform_now

    assert_equal tenant.id, contexts[0][:tenant_id]
    assert_equal collective.id, contexts[0][:collective_id]
    assert_nil contexts[1][:tenant_id], "Tenant context should be cleared after block"
    assert_nil contexts[1][:collective_id], "Collective context should be cleared after block"
  end

  # -----------------------------------
  # Integration Tests
  # -----------------------------------

  test "TenantScopedJob can access scoped data after setting context" do
    # Create a note with context
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note = create_note(tenant: @tenant, collective: @collective, created_by: @user)
    note_id = note.id
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    found_note_id = nil

    job_class = Class.new(TenantScopedJob) do
      attr_accessor :tenant_to_set, :note_id_to_find

      define_method(:perform) do
        set_tenant_context!(tenant_to_set)
        found = Note.find_by(id: note_id_to_find)
        found_note_id = found&.id
      end
    end

    job = job_class.new
    job.tenant_to_set = @tenant
    job.note_id_to_find = note_id
    job.perform_now

    assert_equal note_id, found_note_id, "Should find note with correct tenant context"
  end

  test "SystemJob can access data across tenants using unscoped_for_system_job" do
    # Create notes in two different tenants
    Collective.scope_thread_to_collective(subdomain: @tenant.subdomain, handle: @collective.handle)
    note1 = create_note(tenant: @tenant, collective: @collective, created_by: @user, title: "Tenant 1 note")
    note1_id = note1.id

    tenant2 = create_tenant(subdomain: "system-job-test")
    user2 = create_user
    tenant2.add_user!(user2)
    collective2 = create_collective(tenant: tenant2, created_by: user2, handle: "system-studio")
    collective2.add_user!(user2)

    Collective.scope_thread_to_collective(subdomain: tenant2.subdomain, handle: collective2.handle)
    note2 = create_note(tenant: tenant2, collective: collective2, created_by: user2, title: "Tenant 2 note")
    note2_id = note2.id

    # Clear context
    Tenant.clear_thread_scope
    Collective.clear_thread_scope

    found_ids = []
    note_ids_to_find = [note1_id, note2_id]

    job_class = Class.new(SystemJob) do
      attr_accessor :note_ids

      define_method(:perform) do
        note_ids.each do |id|
          note = Note.unscoped_for_system_job.find_by(id: id)
          found_ids << note.id if note
        end
      end
    end

    job = job_class.new
    job.note_ids = note_ids_to_find
    job.perform_now

    assert_includes found_ids, note1_id, "Should find note from tenant 1"
    assert_includes found_ids, note2_id, "Should find note from tenant 2"
  end
end
