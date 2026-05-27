require "test_helper"

class TenantAnonReadableTest < ActiveSupport::TestCase
  setup do
    @prior_env = ENV.fetch("ANON_READABLE_TENANT_SUBDOMAINS", nil)
    Tenant.reset_anon_readable_subdomains!
  end

  teardown do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = @prior_env
    Tenant.reset_anon_readable_subdomains!
  end

  # ---- Tenant.anon_readable_subdomains ----

  test "anon_readable_subdomains is empty when env var is unset" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = nil
    Tenant.reset_anon_readable_subdomains!
    assert_equal Set.new, Tenant.anon_readable_subdomains
  end

  test "anon_readable_subdomains parses a single subdomain" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "app"
    Tenant.reset_anon_readable_subdomains!
    assert_equal Set["app"], Tenant.anon_readable_subdomains
  end

  test "anon_readable_subdomains parses multiple comma-separated subdomains" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "app,www,demo"
    Tenant.reset_anon_readable_subdomains!
    assert_equal Set["app", "www", "demo"], Tenant.anon_readable_subdomains
  end

  test "anon_readable_subdomains is case-insensitive (lowercased)" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "App,WWW,DeMo"
    Tenant.reset_anon_readable_subdomains!
    assert_equal Set["app", "www", "demo"], Tenant.anon_readable_subdomains
  end

  test "anon_readable_subdomains tolerates whitespace and blanks" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = " app , , www , "
    Tenant.reset_anon_readable_subdomains!
    assert_equal Set["app", "www"], Tenant.anon_readable_subdomains
  end

  test "anon_readable_subdomains memoizes (does not re-read env on subsequent calls)" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "app"
    Tenant.reset_anon_readable_subdomains!
    first = Tenant.anon_readable_subdomains
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "different"
    assert_same first, Tenant.anon_readable_subdomains
  end

  test "reset_anon_readable_subdomains! clears memoization" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "app"
    Tenant.reset_anon_readable_subdomains!
    Tenant.anon_readable_subdomains
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "other"
    Tenant.reset_anon_readable_subdomains!
    assert_equal Set["other"], Tenant.anon_readable_subdomains
  end

  test "anon_readable_subdomains returns a frozen Set" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "app"
    Tenant.reset_anon_readable_subdomains!
    assert Tenant.anon_readable_subdomains.frozen?, "expected frozen Set"
  end

  # ---- Tenant#public_main_collective? ----

  test "public_main_collective? is false when env var is unset (default-deny)" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = nil
    Tenant.reset_anon_readable_subdomains!
    tenant = Tenant.create!(subdomain: "anytest", name: "Any")
    assert_not tenant.public_main_collective?
  end

  test "public_main_collective? is true when subdomain is listed" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "publictest"
    Tenant.reset_anon_readable_subdomains!
    tenant = Tenant.create!(subdomain: "publictest", name: "Public")
    assert tenant.public_main_collective?
  end

  test "public_main_collective? is false when subdomain is not listed" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "publictest"
    Tenant.reset_anon_readable_subdomains!
    tenant = Tenant.create!(subdomain: "privatetest", name: "Private")
    assert_not tenant.public_main_collective?
  end

  test "public_main_collective? matches case-insensitively against tenant subdomain" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "publictest"
    Tenant.reset_anon_readable_subdomains!
    tenant = Tenant.create!(subdomain: "PublicTest", name: "Mixed")
    assert tenant.public_main_collective?, "expected case-insensitive match on tenant subdomain"
  end

  test "public_main_collective? is false for nil subdomain" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "publictest"
    Tenant.reset_anon_readable_subdomains!
    tenant = Tenant.new(subdomain: nil, name: "No subdomain")
    assert_not tenant.public_main_collective?
  end

  # ---- Tenant.warn_unknown_anon_readable_subdomains! (boot validator) ----

  test "warn_unknown_anon_readable_subdomains! is silent when env is unset" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = nil
    Tenant.reset_anon_readable_subdomains!
    io = StringIO.new
    Tenant.warn_unknown_anon_readable_subdomains!(logger: Logger.new(io))
    assert_empty io.string
  end

  test "warn_unknown_anon_readable_subdomains! is silent when every listed subdomain has a tenant" do
    Tenant.create!(subdomain: "warntestone", name: "T1")
    Tenant.create!(subdomain: "warntesttwo", name: "T2")
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "warntestone,warntesttwo"
    Tenant.reset_anon_readable_subdomains!
    io = StringIO.new
    Tenant.warn_unknown_anon_readable_subdomains!(logger: Logger.new(io))
    assert_empty io.string
  end

  test "warn_unknown_anon_readable_subdomains! warns about subdomains with no matching tenant" do
    Tenant.create!(subdomain: "warntestthree", name: "T3")
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "warntestthree,ghostsubdomain"
    Tenant.reset_anon_readable_subdomains!
    io = StringIO.new
    Tenant.warn_unknown_anon_readable_subdomains!(logger: Logger.new(io))
    assert_match(/ghostsubdomain/, io.string)
    assert_match(/ANON_READABLE_TENANT_SUBDOMAINS/, io.string)
    assert_no_match(/warntestthree/, io.string)
  end

  test "warn_unknown_anon_readable_subdomains! does not raise — fails open" do
    ENV["ANON_READABLE_TENANT_SUBDOMAINS"] = "doesnotexistanywhere"
    Tenant.reset_anon_readable_subdomains!
    assert_nothing_raised do
      Tenant.warn_unknown_anon_readable_subdomains!(logger: Logger.new(IO::NULL))
    end
  end
end
