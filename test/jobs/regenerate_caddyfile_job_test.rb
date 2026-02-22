# typed: false

require "test_helper"

class RegenerateCaddyfileJobTest < ActiveJob::TestCase
  def setup
    @tenant, @collective, @user = create_tenant_collective_user
    # Clear tenant context to simulate background job environment
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  def teardown
    Tenant.clear_thread_scope
    Collective.clear_thread_scope
  end

  test "generates Caddyfile with all tenant subdomains" do
    caddy_body = perform_and_capture_body

    assert_includes caddy_body, "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
  end

  test "includes primary and auth subdomains" do
    caddy_body = perform_and_capture_body

    assert_includes caddy_body, "#{ENV['PRIMARY_SUBDOMAIN']}.#{ENV['HOSTNAME']} {"
    assert_includes caddy_body, "#{ENV['AUTH_SUBDOMAIN']}.#{ENV['HOSTNAME']} {"
  end

  test "includes bare domain redirect" do
    caddy_body = perform_and_capture_body

    assert_includes caddy_body, "#{ENV['HOSTNAME']} {"
    assert_includes caddy_body, "redir https://#{ENV['PRIMARY_SUBDOMAIN']}.#{ENV['HOSTNAME']}"
  end

  test "does not duplicate primary or auth subdomains" do
    caddy_body = perform_and_capture_body

    primary_pattern = "#{ENV['PRIMARY_SUBDOMAIN']}.#{ENV['HOSTNAME']} {"
    assert_equal 1, caddy_body.scan(primary_pattern).size,
      "PRIMARY_SUBDOMAIN should appear exactly once"

    auth_pattern = "#{ENV['AUTH_SUBDOMAIN']}.#{ENV['HOSTNAME']} {"
    assert_equal 1, caddy_body.scan(auth_pattern).size,
      "AUTH_SUBDOMAIN should appear exactly once"
  end

  test "includes multiple tenant subdomains" do
    tenant2 = create_tenant(subdomain: "caddyfile-test-2")
    caddy_body = perform_and_capture_body

    assert_includes caddy_body, "#{@tenant.subdomain}.#{ENV['HOSTNAME']}"
    assert_includes caddy_body, "caddyfile-test-2.#{ENV['HOSTNAME']}"
  end

  test "all tenant entries use reverse_proxy web:3000" do
    caddy_body = perform_and_capture_body

    # Every block except the bare domain redirect should have reverse_proxy
    blocks = caddy_body.split(/^(?=\S)/).reject { |b| b.strip.empty? || b.strip == "}" }
    blocks.each do |block|
      next if block.include?("# Auto-generated") # skip header
      next if block.strip.start_with?("#")        # skip comments
      next if block.include?("admin")             # skip global options block

      if block.include?("redir")
        # Bare domain redirect block
        assert_includes block, "redir https://", "Bare domain should redirect"
      else
        assert_includes block, "reverse_proxy web:3000",
          "Block should proxy to web:3000: #{block}"
      end
    end
  end

  test "handles Caddy connection refused gracefully" do
    stub_request(:post, "http://caddy:2019/load")
      .to_raise(Errno::ECONNREFUSED)

    assert_nothing_raised do
      RegenerateCaddyfileJob.perform_now
    end
  end

  test "raises on non-2xx Caddy response" do
    stub_request(:post, "http://caddy:2019/load")
      .to_return(status: 400, body: "invalid config")

    assert_raises(RuntimeError) do
      RegenerateCaddyfileJob.perform_now
    end
  end

  # --- Callback tests ---

  test "enqueues job when tenant is created" do
    assert_enqueued_with(job: RegenerateCaddyfileJob) do
      create_tenant(subdomain: "caddyfile-callback-test")
    end
  end

  test "enqueues job when tenant is destroyed" do
    tenant2 = create_tenant(subdomain: "caddyfile-destroy-test")

    assert_enqueued_with(job: RegenerateCaddyfileJob) do
      tenant2.destroy!
    end
  end

  test "enqueues job when tenant subdomain changes" do
    assert_enqueued_with(job: RegenerateCaddyfileJob) do
      @tenant.update!(subdomain: "caddyfile-renamed")
    end
  end

  test "does not enqueue job when non-subdomain fields change" do
    # Clear any previously enqueued jobs from setup
    queue_adapter.enqueued_jobs.clear

    @tenant.update!(name: "Updated Name")

    caddyfile_jobs = queue_adapter.enqueued_jobs.select do |job|
      job["job_class"] == "RegenerateCaddyfileJob"
    end
    assert_empty caddyfile_jobs, "Should not enqueue RegenerateCaddyfileJob for name change"
  end

  private

  def perform_and_capture_body
    captured_body = nil
    stub_request(:post, "http://caddy:2019/load")
      .to_return { |request| captured_body = request.body; { status: 200, body: "" } }

    RegenerateCaddyfileJob.perform_now
    captured_body
  end
end
