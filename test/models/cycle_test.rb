require "test_helper"

class CycleTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "cycle-test-#{SecureRandom.hex(4)}")
    @user = create_user(email: "cycletest_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@user)
    @superagent = create_superagent(tenant: @tenant, created_by: @user, handle: "cycle-studio-#{SecureRandom.hex(4)}")
    @superagent.settings["timezone"] = "UTC"
    @superagent.save!
  end

  # === Factory Tests ===

  test "new_from_tempo creates daily cycle for daily tempo" do
    @superagent.settings["tempo"] = "daily"
    @superagent.save!

    cycle = Cycle.new_from_tempo(tenant: @tenant, superagent: @superagent)
    assert_equal "today", cycle.name
    assert_equal "day", cycle.unit
  end

  test "new_from_tempo creates weekly cycle for weekly tempo" do
    @superagent.settings["tempo"] = "weekly"
    @superagent.save!

    cycle = Cycle.new_from_tempo(tenant: @tenant, superagent: @superagent)
    assert_equal "this-week", cycle.name
    assert_equal "week", cycle.unit
  end

  test "new_from_tempo creates monthly cycle for monthly tempo" do
    @superagent.settings["tempo"] = "monthly"
    @superagent.save!

    cycle = Cycle.new_from_tempo(tenant: @tenant, superagent: @superagent)
    assert_equal "this-month", cycle.name
    assert_equal "month", cycle.unit
  end

  test "new_from_tempo creates yearly cycle for yearly tempo" do
    @superagent.settings["tempo"] = "yearly"
    @superagent.save!

    cycle = Cycle.new_from_tempo(tenant: @tenant, superagent: @superagent)
    assert_equal "this-year", cycle.name
    assert_equal "year", cycle.unit
  end

  test "new_from_studio uses studio's tempo" do
    @superagent.settings["tempo"] = "weekly"
    @superagent.save!

    cycle = Cycle.new_from_superagent(@superagent)
    assert_equal "this-week", cycle.name
  end

  test "new_from_end_of_cycle_option parses option correctly" do
    cycle = Cycle.new_from_end_of_cycle_option(
      end_of_cycle: "end of this week",
      tenant: @tenant,
      superagent: @superagent
    )
    assert_equal "this-week", cycle.name
  end

  # === Unit Calculation Tests ===

  test "unit returns day for today" do
    cycle = Cycle.new(name: "today", tenant: @tenant, superagent: @superagent)
    assert_equal "day", cycle.unit
  end

  test "unit returns day for yesterday" do
    cycle = Cycle.new(name: "yesterday", tenant: @tenant, superagent: @superagent)
    assert_equal "day", cycle.unit
  end

  test "unit returns day for tomorrow" do
    cycle = Cycle.new(name: "tomorrow", tenant: @tenant, superagent: @superagent)
    assert_equal "day", cycle.unit
  end

  test "unit returns week for this-week" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, superagent: @superagent)
    assert_equal "week", cycle.unit
  end

  test "unit returns week for last-week" do
    cycle = Cycle.new(name: "last-week", tenant: @tenant, superagent: @superagent)
    assert_equal "week", cycle.unit
  end

  test "unit returns month for this-month" do
    cycle = Cycle.new(name: "this-month", tenant: @tenant, superagent: @superagent)
    assert_equal "month", cycle.unit
  end

  test "unit returns year for this-year" do
    cycle = Cycle.new(name: "this-year", tenant: @tenant, superagent: @superagent)
    assert_equal "year", cycle.unit
  end

  # === Date Calculation Tests ===

  test "start_date for today is beginning of day" do
    cycle = Cycle.new(name: "today", tenant: @tenant, superagent: @superagent)
    assert_equal Time.current.in_time_zone("UTC").beginning_of_day.to_date, cycle.start_date.to_date
  end

  test "start_date for yesterday is beginning of yesterday" do
    cycle = Cycle.new(name: "yesterday", tenant: @tenant, superagent: @superagent)
    expected = (Time.current - 1.day).in_time_zone("UTC").beginning_of_day.to_date
    assert_equal expected, cycle.start_date.to_date
  end

  test "start_date for tomorrow is beginning of tomorrow" do
    cycle = Cycle.new(name: "tomorrow", tenant: @tenant, superagent: @superagent)
    expected = (Time.current + 1.day).in_time_zone("UTC").beginning_of_day.to_date
    assert_equal expected, cycle.start_date.to_date
  end

  test "start_date for this-week is beginning of week" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, superagent: @superagent)
    expected = Time.current.in_time_zone("UTC").beginning_of_week.to_date
    assert_equal expected, cycle.start_date.to_date
  end

  test "end_date is one unit after start_date" do
    cycle = Cycle.new(name: "today", tenant: @tenant, superagent: @superagent)
    expected = cycle.start_date + 1.day
    assert_equal expected, cycle.end_date
  end

  test "window returns range from start to end" do
    cycle = Cycle.new(name: "today", tenant: @tenant, superagent: @superagent)
    assert_equal cycle.start_date..cycle.end_date, cycle.window
  end

  # === Display Tests ===

  test "display_name titleizes cycle name" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, superagent: @superagent)
    assert_equal "This Week", cycle.display_name
  end

  test "display_window formats day correctly" do
    cycle = Cycle.new(name: "today", tenant: @tenant, superagent: @superagent)
    # Should include day name, month, date, year
    assert_match(/\w+day/, cycle.display_window)  # Contains day name
    assert_match(/\d{4}/, cycle.display_window)   # Contains year
  end

  test "display_window does not contain double spaces for single-digit days" do
    # Test with a fixed date that has a single-digit day
    travel_to Time.zone.local(2026, 1, 9, 12, 0, 0) do
      cycle = Cycle.new(name: "today", tenant: @tenant, superagent: @superagent)
      display = cycle.display_window
      # Should not have double spaces (e.g., "January  9" should be "January 9")
      refute_match(/  /, display, "display_window should not contain double spaces: #{display}")
      # Should contain the single-digit day without leading space padding
      assert_match(/January 9/, display, "display_window should format single-digit day without padding: #{display}")
    end
  end

  test "display_window formats week as range" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, superagent: @superagent)
    assert_match(/-/, cycle.display_window)  # Contains dash for range
  end

  test "display_duration returns 1 day for day unit" do
    cycle = Cycle.new(name: "today", tenant: @tenant, superagent: @superagent)
    assert_equal "1 day", cycle.display_duration
  end

  test "display_duration returns 1 week for week unit" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, superagent: @superagent)
    assert_equal "1 week", cycle.display_duration
  end

  # === Path Tests ===

  test "path returns studio path with cycle name" do
    cycle = Cycle.new(name: "today", tenant: @tenant, superagent: @superagent)
    assert_equal "#{@superagent.path}/cycles/today", cycle.path
  end

  test "id returns Cycles > display_name format" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, superagent: @superagent)
    assert_equal "Cycles > This Week", cycle.id
  end

  # === Previous Cycle Tests ===

  test "previous_cycle returns yesterday for today" do
    cycle = Cycle.new(name: "today", tenant: @tenant, superagent: @superagent)
    assert_equal "yesterday", cycle.previous_cycle
  end

  test "previous_cycle returns last-week for this-week" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, superagent: @superagent)
    assert_equal "last-week", cycle.previous_cycle
  end

  test "previous_cycle returns last-month for this-month" do
    cycle = Cycle.new(name: "this-month", tenant: @tenant, superagent: @superagent)
    assert_equal "last-month", cycle.previous_cycle
  end

  # === API JSON Tests ===

  test "api_json returns expected fields" do
    cycle = Cycle.new(name: "today", tenant: @tenant, superagent: @superagent)
    json = cycle.api_json

    assert_equal "today", json[:name]
    assert_equal "Today", json[:display_name]
    assert_equal "day", json[:unit]
    assert_not_nil json[:start_date]
    assert_not_nil json[:end_date]
    assert_not_nil json[:time_window]
    assert_not_nil json[:counts]
  end

  # === End of Cycle Options Tests ===

  test "end_of_cycle_options returns list of options" do
    options = Cycle.end_of_cycle_options(tempo: "daily")
    assert_includes options, "end of day today"
    assert_includes options, "end of day tomorrow"
    assert_includes options, "end of this week"
    assert_includes options, "end of this month"
    assert_includes options, "end of this year"
  end

  # === Validation Tests ===

  test "initialize requires tenant" do
    # Sorbet runtime type checking raises TypeError before our manual nil check
    assert_raises TypeError do
      Cycle.new(name: "today", tenant: nil, superagent: @superagent)
    end
  end

  test "initialize requires studio" do
    # Sorbet runtime type checking raises TypeError before our manual nil check
    assert_raises TypeError do
      Cycle.new(name: "today", tenant: @tenant, superagent: nil)
    end
  end

  # === Sort and Group Options ===

  test "cycle_options returns all cycle options" do
    cycle = Cycle.new(name: "today", tenant: @tenant, superagent: @superagent)
    options = cycle.cycle_options

    assert_equal 12, options.length
    assert_includes options, ["Today", "today"]
    assert_includes options, ["Yesterday", "yesterday"]
    assert_includes options, ["This week", "this-week"]
  end

  test "sort_by_options returns available sort options" do
    cycle = Cycle.new(name: "today", tenant: @tenant, superagent: @superagent)
    options = cycle.sort_by_options

    assert options.any? { |o| o[1].include?("deadline") }
    assert options.any? { |o| o[1].include?("created_at") }
    assert options.any? { |o| o[1].include?("updated_at") }
  end
end
