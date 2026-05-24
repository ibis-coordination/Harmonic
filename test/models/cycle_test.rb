require "test_helper"

class CycleTest < ActiveSupport::TestCase
  def setup
    @tenant = create_tenant(subdomain: "cycle-test-#{SecureRandom.hex(4)}")
    @user = create_user(email: "cycletest_#{SecureRandom.hex(4)}@example.com")
    @tenant.add_user!(@user)
    @collective = create_collective(tenant: @tenant, created_by: @user, handle: "cycle-collective-#{SecureRandom.hex(4)}")
    @collective.settings["timezone"] = "UTC"
    @collective.save!
  end

  # === Factory Tests ===

  test "new_from_tempo creates daily cycle for daily tempo" do
    @collective.settings["tempo"] = "daily"
    @collective.save!

    cycle = Cycle.new_from_tempo(tenant: @tenant, collective: @collective)
    assert_equal "today", cycle.name
    assert_equal "day", cycle.unit
  end

  test "new_from_tempo creates weekly cycle for weekly tempo" do
    @collective.settings["tempo"] = "weekly"
    @collective.save!

    cycle = Cycle.new_from_tempo(tenant: @tenant, collective: @collective)
    assert_equal "this-week", cycle.name
    assert_equal "week", cycle.unit
  end

  test "new_from_tempo creates monthly cycle for monthly tempo" do
    @collective.settings["tempo"] = "monthly"
    @collective.save!

    cycle = Cycle.new_from_tempo(tenant: @tenant, collective: @collective)
    assert_equal "this-month", cycle.name
    assert_equal "month", cycle.unit
  end

  test "new_from_tempo creates yearly cycle for yearly tempo" do
    @collective.settings["tempo"] = "yearly"
    @collective.save!

    cycle = Cycle.new_from_tempo(tenant: @tenant, collective: @collective)
    assert_equal "this-year", cycle.name
    assert_equal "year", cycle.unit
  end

  test "new_from_collective uses collective's tempo" do
    @collective.settings["tempo"] = "weekly"
    @collective.save!

    cycle = Cycle.new_from_collective(@collective)
    assert_equal "this-week", cycle.name
  end

  test "new_from_end_of_cycle_option parses option correctly" do
    cycle = Cycle.new_from_end_of_cycle_option(
      end_of_cycle: "end of this week",
      tenant: @tenant,
      collective: @collective
    )
    assert_equal "this-week", cycle.name
  end

  # === Unit Calculation Tests ===

  test "unit returns day for today" do
    cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
    assert_equal "day", cycle.unit
  end

  test "unit returns day for yesterday" do
    cycle = Cycle.new(name: "yesterday", tenant: @tenant, collective: @collective)
    assert_equal "day", cycle.unit
  end

  test "unit returns day for tomorrow" do
    cycle = Cycle.new(name: "tomorrow", tenant: @tenant, collective: @collective)
    assert_equal "day", cycle.unit
  end

  test "unit returns week for this-week" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, collective: @collective)
    assert_equal "week", cycle.unit
  end

  test "unit returns week for last-week" do
    cycle = Cycle.new(name: "last-week", tenant: @tenant, collective: @collective)
    assert_equal "week", cycle.unit
  end

  test "unit returns month for this-month" do
    cycle = Cycle.new(name: "this-month", tenant: @tenant, collective: @collective)
    assert_equal "month", cycle.unit
  end

  test "unit returns year for this-year" do
    cycle = Cycle.new(name: "this-year", tenant: @tenant, collective: @collective)
    assert_equal "year", cycle.unit
  end

  # === Date Calculation Tests ===

  test "start_date for today is beginning of day" do
    cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
    assert_equal Time.current.in_time_zone("UTC").beginning_of_day.to_date, cycle.start_date.to_date
  end

  test "start_date for yesterday is beginning of yesterday" do
    cycle = Cycle.new(name: "yesterday", tenant: @tenant, collective: @collective)
    expected = 1.day.ago.in_time_zone("UTC").beginning_of_day.to_date
    assert_equal expected, cycle.start_date.to_date
  end

  test "start_date for tomorrow is beginning of tomorrow" do
    cycle = Cycle.new(name: "tomorrow", tenant: @tenant, collective: @collective)
    expected = 1.day.from_now.in_time_zone("UTC").beginning_of_day.to_date
    assert_equal expected, cycle.start_date.to_date
  end

  test "start_date for this-week is beginning of week" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, collective: @collective)
    expected = Time.current.in_time_zone("UTC").beginning_of_week.to_date
    assert_equal expected, cycle.start_date.to_date
  end

  test "end_date is one unit after start_date" do
    cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
    expected = cycle.start_date + 1.day
    assert_equal expected, cycle.end_date
  end

  test "window returns range from start to end" do
    cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
    assert_equal cycle.start_date..cycle.end_date, cycle.window
  end

  # === Display Tests ===

  test "display_name titleizes cycle name" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, collective: @collective)
    assert_equal "This Week", cycle.display_name
  end

  test "display_window formats day correctly" do
    cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
    # Should include day name, month, date, year
    assert_match(/\w+day/, cycle.display_window)  # Contains day name
    assert_match(/\d{4}/, cycle.display_window)   # Contains year
  end

  test "display_window does not contain double spaces for single-digit days" do
    # Test with a fixed date that has a single-digit day
    travel_to Time.zone.local(2026, 1, 9, 12, 0, 0) do
      cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
      display = cycle.display_window
      # Should not have double spaces (e.g., "January  9" should be "January 9")
      assert_no_match(/  /, display, "display_window should not contain double spaces: #{display}")
      # Should contain the single-digit day without leading space padding
      assert_match(/January 9/, display, "display_window should format single-digit day without padding: #{display}")
    end
  end

  test "display_window formats week as range" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, collective: @collective)
    assert_match(/-/, cycle.display_window) # Contains dash for range
  end

  test "display_duration returns 1 day for day unit" do
    cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
    assert_equal "1 day", cycle.display_duration
  end

  test "display_duration returns 1 week for week unit" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, collective: @collective)
    assert_equal "1 week", cycle.display_duration
  end

  # === Path Tests ===

  test "path returns collective path with cycle name" do
    cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
    assert_equal "#{@collective.path}/cycles/today", cycle.path
  end

  test "id returns Cycles > display_name format" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, collective: @collective)
    assert_equal "Cycles > This Week", cycle.id
  end

  # === Previous Cycle Tests ===

  test "previous_cycle returns yesterday for today" do
    cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
    assert_equal "yesterday", cycle.previous_cycle
  end

  test "previous_cycle returns last-week for this-week" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, collective: @collective)
    assert_equal "last-week", cycle.previous_cycle
  end

  test "previous_cycle returns last-month for this-month" do
    cycle = Cycle.new(name: "this-month", tenant: @tenant, collective: @collective)
    assert_equal "last-month", cycle.previous_cycle
  end

  # === Next Cycle Tests ===

  test "next_cycle returns nil for today" do
    cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
    assert_nil cycle.next_cycle
  end

  test "next_cycle returns today for yesterday" do
    cycle = Cycle.new(name: "yesterday", tenant: @tenant, collective: @collective)
    assert_equal "today", cycle.next_cycle
  end

  test "next_cycle returns nil for this-week" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, collective: @collective)
    assert_nil cycle.next_cycle
  end

  test "next_cycle returns this-week for last-week" do
    cycle = Cycle.new(name: "last-week", tenant: @tenant, collective: @collective)
    assert_equal "this-week", cycle.next_cycle
  end

  test "next_cycle returns nil for this-month" do
    cycle = Cycle.new(name: "this-month", tenant: @tenant, collective: @collective)
    assert_nil cycle.next_cycle
  end

  test "next_cycle returns this-month for last-month" do
    cycle = Cycle.new(name: "last-month", tenant: @tenant, collective: @collective)
    assert_equal "this-month", cycle.next_cycle
  end

  # === Is Current Cycle Tests ===

  test "is_current_cycle? returns true for today" do
    cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
    assert cycle.is_current_cycle?
  end

  test "is_current_cycle? returns true for this-week" do
    cycle = Cycle.new(name: "this-week", tenant: @tenant, collective: @collective)
    assert cycle.is_current_cycle?
  end

  test "is_current_cycle? returns true for this-month" do
    cycle = Cycle.new(name: "this-month", tenant: @tenant, collective: @collective)
    assert cycle.is_current_cycle?
  end

  test "is_current_cycle? returns false for yesterday" do
    cycle = Cycle.new(name: "yesterday", tenant: @tenant, collective: @collective)
    assert_not cycle.is_current_cycle?
  end

  test "is_current_cycle? returns false for last-week" do
    cycle = Cycle.new(name: "last-week", tenant: @tenant, collective: @collective)
    assert_not cycle.is_current_cycle?
  end

  test "is_current_cycle? returns false for last-month" do
    cycle = Cycle.new(name: "last-month", tenant: @tenant, collective: @collective)
    assert_not cycle.is_current_cycle?
  end

  # === Multi-step Navigation Tests ===

  test "previous_cycle returns 2-days-ago for yesterday" do
    cycle = Cycle.new(name: "yesterday", tenant: @tenant, collective: @collective)
    assert_equal "2-days-ago", cycle.previous_cycle
  end

  test "previous_cycle returns 3-days-ago for 2-days-ago" do
    cycle = Cycle.new(name: "2-days-ago", tenant: @tenant, collective: @collective)
    assert_equal "3-days-ago", cycle.previous_cycle
  end

  test "previous_cycle returns 2-weeks-ago for last-week" do
    cycle = Cycle.new(name: "last-week", tenant: @tenant, collective: @collective)
    assert_equal "2-weeks-ago", cycle.previous_cycle
  end

  test "previous_cycle returns 3-weeks-ago for 2-weeks-ago" do
    cycle = Cycle.new(name: "2-weeks-ago", tenant: @tenant, collective: @collective)
    assert_equal "3-weeks-ago", cycle.previous_cycle
  end

  test "next_cycle returns yesterday for 2-days-ago" do
    cycle = Cycle.new(name: "2-days-ago", tenant: @tenant, collective: @collective)
    assert_equal "yesterday", cycle.next_cycle
  end

  test "next_cycle returns 2-days-ago for 3-days-ago" do
    cycle = Cycle.new(name: "3-days-ago", tenant: @tenant, collective: @collective)
    assert_equal "2-days-ago", cycle.next_cycle
  end

  test "next_cycle returns last-week for 2-weeks-ago" do
    cycle = Cycle.new(name: "2-weeks-ago", tenant: @tenant, collective: @collective)
    assert_equal "last-week", cycle.next_cycle
  end

  test "next_cycle returns 2-weeks-ago for 3-weeks-ago" do
    cycle = Cycle.new(name: "3-weeks-ago", tenant: @tenant, collective: @collective)
    assert_equal "2-weeks-ago", cycle.next_cycle
  end

  # === Offset Tests ===

  test "offset returns 0 for today" do
    cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
    assert_equal 0, cycle.offset
  end

  test "offset returns -1 for yesterday" do
    cycle = Cycle.new(name: "yesterday", tenant: @tenant, collective: @collective)
    assert_equal(-1, cycle.offset)
  end

  test "offset returns -2 for 2-days-ago" do
    cycle = Cycle.new(name: "2-days-ago", tenant: @tenant, collective: @collective)
    assert_equal(-2, cycle.offset)
  end

  test "offset returns -3 for 3-weeks-ago" do
    cycle = Cycle.new(name: "3-weeks-ago", tenant: @tenant, collective: @collective)
    assert_equal(-3, cycle.offset)
  end

  test "unit returns day for N-days-ago patterns" do
    cycle = Cycle.new(name: "5-days-ago", tenant: @tenant, collective: @collective)
    assert_equal "day", cycle.unit
  end

  test "unit returns week for N-weeks-ago patterns" do
    cycle = Cycle.new(name: "4-weeks-ago", tenant: @tenant, collective: @collective)
    assert_equal "week", cycle.unit
  end

  test "unit returns month for N-months-ago patterns" do
    cycle = Cycle.new(name: "3-months-ago", tenant: @tenant, collective: @collective)
    assert_equal "month", cycle.unit
  end

  test "start_date for 2-weeks-ago is 2 weeks before this week" do
    cycle_this_week = Cycle.new(name: "this-week", tenant: @tenant, collective: @collective)
    cycle_2_weeks_ago = Cycle.new(name: "2-weeks-ago", tenant: @tenant, collective: @collective)
    assert_equal cycle_this_week.start_date - 2.weeks, cycle_2_weeks_ago.start_date
  end

  test "display_name formats N-days-ago correctly" do
    cycle = Cycle.new(name: "3-days-ago", tenant: @tenant, collective: @collective)
    assert_equal "3 Days Ago", cycle.display_name
  end

  # === API JSON Tests ===

  test "api_json returns expected fields" do
    cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
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
      Cycle.new(name: "today", tenant: nil, collective: @collective)
    end
  end

  test "initialize requires collective" do
    # Sorbet runtime type checking raises TypeError before our manual nil check
    assert_raises TypeError do
      Cycle.new(name: "today", tenant: @tenant, collective: nil)
    end
  end

  # === Sort and Group Options ===

  test "cycle_options returns all cycle options" do
    cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
    options = cycle.cycle_options

    assert_equal 12, options.length
    assert_includes options, ["Today", "today"]
    assert_includes options, ["Yesterday", "yesterday"]
    assert_includes options, ["This week", "this-week"]
  end

  test "sort_by_options returns available sort options" do
    cycle = Cycle.new(name: "today", tenant: @tenant, collective: @collective)
    options = cycle.sort_by_options

    assert(options.any? { |o| o[1].include?("deadline") })
    assert(options.any? { |o| o[1].include?("created_at") })
    assert(options.any? { |o| o[1].include?("updated_at") })
  end

  # === Recent Summaries Tests ===

  test "recent_summaries returns empty when collective has no content" do
    @collective.settings["tempo"] = "weekly"
    @collective.save!

    summaries = Cycle.recent_summaries(collective: @collective, tenant: @tenant)
    assert_equal [], summaries.to_a
  end

  test "recent_summaries returns one row per cycle bucket with counts" do
    @collective.settings["tempo"] = "weekly"
    @collective.save!

    travel_to Time.zone.local(2026, 5, 15, 12, 0, 0) do
      # This week (May 11-17, 2026): 2 notes, 1 decision
      create_note(title: "n1")
      create_note(title: "n2")
      create_decision(question: "d1?")

      # Last week
      last_week_note = create_note(title: "n3")
      last_week_commitment = create_commitment(title: "c1")
      last_week_time = Time.zone.local(2026, 5, 8, 12, 0, 0)
      last_week_note.update_columns(created_at: last_week_time)
      last_week_commitment.update_columns(created_at: last_week_time)

      summaries = Cycle.recent_summaries(collective: @collective, tenant: @tenant).to_a

      assert_equal 2, summaries.length

      this_week = summaries.find { |s| s.notes_count == 2 }
      last_week = summaries.find { |s| s.notes_count == 1 }
      assert_not_nil this_week
      assert_not_nil last_week

      assert_equal 3, this_week.total_count
      assert_equal 2, this_week.notes_count
      assert_equal 1, this_week.decisions_count
      assert_equal 0, this_week.commitments_count

      assert_equal 2, last_week.total_count
      assert_equal 1, last_week.notes_count
      assert_equal 0, last_week.decisions_count
      assert_equal 1, last_week.commitments_count
    end
  end

  test "recent_summaries orders most recent first" do
    @collective.settings["tempo"] = "weekly"
    @collective.save!

    travel_to Time.zone.local(2026, 5, 15, 12, 0, 0) do
      create_note(title: "this-week")
      last_week_note = create_note(title: "last-week")
      last_week_note.update_columns(created_at: Time.zone.local(2026, 5, 8, 12, 0, 0))
      two_weeks_ago_note = create_note(title: "two-weeks-ago")
      two_weeks_ago_note.update_columns(created_at: Time.zone.local(2026, 5, 1, 12, 0, 0))

      summaries = Cycle.recent_summaries(collective: @collective, tenant: @tenant).to_a
      starts = summaries.map(&:cycle_start)
      assert_equal starts.sort.reverse, starts
    end
  end

  test "recent_summaries is scoped to collective" do
    @collective.settings["tempo"] = "weekly"
    @collective.save!
    other_collective = create_collective(
      tenant: @tenant,
      created_by: @user,
      handle: "other-collective-#{SecureRandom.hex(4)}"
    )

    create_note(collective: @collective, title: "ours")
    create_note(collective: other_collective, title: "theirs")

    summaries = Cycle.recent_summaries(collective: @collective, tenant: @tenant).to_a
    total = summaries.sum(&:total_count)
    assert_equal 1, total
  end

  test "recent_summaries excludes cycles older than limit" do
    @collective.settings["tempo"] = "weekly"
    @collective.save!

    travel_to Time.zone.local(2026, 5, 15, 12, 0, 0) do
      create_note(title: "recent")
      ancient = create_note(title: "ancient")
      ancient.update_columns(created_at: Time.zone.local(2025, 1, 1, 12, 0, 0))

      summaries = Cycle.recent_summaries(collective: @collective, tenant: @tenant, limit: 6).to_a
      assert_equal 1, summaries.length
    end
  end

  test "recent_summaries excludes comments from note count" do
    @collective.settings["tempo"] = "weekly"
    @collective.save!

    travel_to Time.zone.local(2026, 5, 15, 12, 0, 0) do
      parent = create_note(title: "parent")
      create_note(title: "real note")
      create_note(title: "comment-1", commentable: parent)
      create_note(title: "comment-2", commentable: parent)

      summaries = Cycle.recent_summaries(collective: @collective, tenant: @tenant).to_a
      # parent + real note = 2 (comments excluded)
      assert_equal 2, summaries.first.notes_count
    end
  end

  test "recent_summaries excludes soft-deleted items" do
    @collective.settings["tempo"] = "weekly"
    @collective.save!

    travel_to Time.zone.local(2026, 5, 15, 12, 0, 0) do
      kept = create_note(title: "kept")
      deleted = create_note(title: "deleted")
      deleted.soft_delete!(by: @user)

      summaries = Cycle.recent_summaries(collective: @collective, tenant: @tenant).to_a
      assert_equal 1, summaries.length
      assert_equal 1, summaries.first.notes_count
      assert_equal 1, summaries.first.total_count
      kept.destroy
    end
  end

  test "recent_summaries buckets by day when tempo is daily" do
    @collective.settings["tempo"] = "daily"
    @collective.save!

    travel_to Time.zone.local(2026, 5, 15, 12, 0, 0) do
      create_note(title: "today")
      yest = create_note(title: "yesterday")
      yest.update_columns(created_at: Time.zone.local(2026, 5, 14, 12, 0, 0))

      summaries = Cycle.recent_summaries(collective: @collective, tenant: @tenant).to_a
      assert_equal 2, summaries.length
    end
  end

  test "recent_summaries buckets by month when tempo is monthly" do
    @collective.settings["tempo"] = "monthly"
    @collective.save!

    travel_to Time.zone.local(2026, 5, 15, 12, 0, 0) do
      create_note(title: "may")
      april = create_note(title: "april")
      april.update_columns(created_at: Time.zone.local(2026, 4, 10, 12, 0, 0))
      march = create_note(title: "march")
      march.update_columns(created_at: Time.zone.local(2026, 3, 5, 12, 0, 0))

      summaries = Cycle.recent_summaries(collective: @collective, tenant: @tenant).to_a
      assert_equal 3, summaries.length
    end
  end

  test "recent_summaries is scoped to tenant" do
    @collective.settings["tempo"] = "weekly"
    @collective.save!

    other_tenant = create_tenant(subdomain: "other-#{SecureRandom.hex(4)}")
    other_user = create_user(email: "other_#{SecureRandom.hex(4)}@example.com")
    other_tenant.add_user!(other_user)
    other_collective = Collective.create!(
      tenant: other_tenant,
      created_by: other_user,
      handle: "other-#{SecureRandom.hex(4)}",
      name: "Other"
    )

    create_note(collective: @collective, title: "ours")
    Note.create!(
      tenant: other_tenant,
      collective: other_collective,
      created_by: other_user,
      title: "theirs",
      text: "x",
      subtype: "post",
      deadline: 1.week.from_now
    )

    summaries = Cycle.recent_summaries(collective: @collective, tenant: @tenant).to_a
    assert_equal 1, summaries.sum(&:total_count)
  end

  test "recent_summaries respects collective timezone for bucket boundaries" do
    @collective.settings["tempo"] = "daily"
    @collective.settings["timezone"] = "Australia/Sydney"
    @collective.save!

    # Sydney is UTC+10/+11. A note created at 23:00 UTC on May 14 is May 15 in Sydney.
    travel_to Time.zone.local(2026, 5, 16, 12, 0, 0) do
      sydney_may_15 = create_note(title: "sydney-may-15")
      sydney_may_15.update_columns(created_at: Time.utc(2026, 5, 14, 23, 0, 0))

      sydney_may_14 = create_note(title: "sydney-may-14")
      sydney_may_14.update_columns(created_at: Time.utc(2026, 5, 13, 23, 0, 0))

      summaries = Cycle.recent_summaries(collective: @collective, tenant: @tenant).to_a
      # Two distinct day buckets in Sydney time
      assert_equal 2, summaries.length
    end
  end

  test "recent_summaries returns RecentCycleSummary structs" do
    @collective.settings["tempo"] = "weekly"
    @collective.save!
    create_note(title: "n")
    summaries = Cycle.recent_summaries(collective: @collective, tenant: @tenant).to_a
    assert_kind_of Cycle::RecentCycleSummary, summaries.first
  end

  # === cycle_name_for_offset Tests ===

  test "cycle_name_for_offset returns named cycles for current and recent offsets in day unit" do
    assert_equal "today", Cycle.cycle_name_for_offset(0, "day")
    assert_equal "yesterday", Cycle.cycle_name_for_offset(-1, "day")
    assert_equal "2-days-ago", Cycle.cycle_name_for_offset(-2, "day")
    assert_equal "5-days-ago", Cycle.cycle_name_for_offset(-5, "day")
  end

  test "cycle_name_for_offset returns named cycles for week unit" do
    assert_equal "this-week", Cycle.cycle_name_for_offset(0, "week")
    assert_equal "last-week", Cycle.cycle_name_for_offset(-1, "week")
    assert_equal "3-weeks-ago", Cycle.cycle_name_for_offset(-3, "week")
  end

  test "cycle_name_for_offset returns named cycles for month unit" do
    assert_equal "this-month", Cycle.cycle_name_for_offset(0, "month")
    assert_equal "last-month", Cycle.cycle_name_for_offset(-1, "month")
    assert_equal "4-months-ago", Cycle.cycle_name_for_offset(-4, "month")
  end

  test "cycle_name_for_offset handles offset 1 as next" do
    assert_equal "tomorrow", Cycle.cycle_name_for_offset(1, "day")
    assert_equal "next-week", Cycle.cycle_name_for_offset(1, "week")
    assert_equal "next-month", Cycle.cycle_name_for_offset(1, "month")
    assert_equal "next-year", Cycle.cycle_name_for_offset(1, "year")
  end

  test "cycle_name_for_offset raises for offsets beyond +1 (no name)" do
    assert_raises(RuntimeError) { Cycle.cycle_name_for_offset(2, "week") }
    assert_raises(RuntimeError) { Cycle.cycle_name_for_offset(5, "day") }
  end

  test "cycle_name_for_offset raises for invalid unit" do
    assert_raises(RuntimeError) { Cycle.cycle_name_for_offset(0, "decade") }
  end

  # === Calendar event cycle membership ===

  test "calendar_event commitments appear in cycle containing starts_at, not created_at" do
    @collective.settings["tempo"] = "weekly"
    @collective.save!

    next_week_starts = 1.week.from_now.beginning_of_week + 1.day + 10.hours
    event = Commitment.create!(
      tenant: @tenant, collective: @collective, created_by: @user, updated_by: @user,
      title: "Next week meeting", subtype: "calendar_event",
      starts_at: next_week_starts, ends_at: next_week_starts + 1.hour,
      critical_mass: 1, deadline: next_week_starts
    )

    this_week = Cycle.new(name: "this-week", tenant: @tenant, collective: @collective)
    next_week = Cycle.new(name: "next-week", tenant: @tenant, collective: @collective)

    assert_not_includes this_week.commitments.pluck(:id), event.id
    assert_includes next_week.commitments.pluck(:id), event.id
  end

  test "action commitments use created_at for cycle membership" do
    @collective.settings["tempo"] = "weekly"
    @collective.save!

    action = Commitment.create!(
      tenant: @tenant, collective: @collective, created_by: @user, updated_by: @user,
      title: "Action this week", subtype: "action",
      critical_mass: 3, deadline: 2.weeks.from_now
    )

    this_week = Cycle.new(name: "this-week", tenant: @tenant, collective: @collective)
    assert_includes this_week.commitments.pluck(:id), action.id
  end

  test "cycle_name_for_offset round-trips through Cycle parsing" do
    # Names produced should parse back to the same offset via Cycle#offset
    [
      [0, "day"], [-1, "day"], [-3, "day"],
      [0, "week"], [-1, "week"], [-2, "week"],
      [0, "month"], [-1, "month"], [-5, "month"],
    ].each do |offset, unit|
      name = Cycle.cycle_name_for_offset(offset, unit)
      cycle = Cycle.new(name: name, tenant: @tenant, collective: @collective)
      assert_equal offset, cycle.offset, "expected #{name} to have offset #{offset}"
      assert_equal unit, cycle.unit, "expected #{name} to have unit #{unit}"
    end
  end
end
