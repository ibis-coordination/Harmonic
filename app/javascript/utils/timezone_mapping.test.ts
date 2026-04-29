import { describe, it, expect } from "vitest"
import { ianaToRailsTimezone, railsToIanaTimezone, parseDatetimeInTimezone } from "./timezone_mapping"

describe("ianaToRailsTimezone", () => {
  it("maps common US timezones", () => {
    expect(ianaToRailsTimezone("America/New_York")).toBe("Eastern Time (US & Canada)")
    expect(ianaToRailsTimezone("America/Chicago")).toBe("Central Time (US & Canada)")
    expect(ianaToRailsTimezone("America/Denver")).toBe("Mountain Time (US & Canada)")
    expect(ianaToRailsTimezone("America/Los_Angeles")).toBe("Pacific Time (US & Canada)")
  })

  it("maps European timezones", () => {
    expect(ianaToRailsTimezone("Europe/London")).toBe("Edinburgh")
    expect(ianaToRailsTimezone("Europe/Paris")).toBe("Paris")
    expect(ianaToRailsTimezone("Europe/Berlin")).toBe("Berlin")
  })

  it("maps Asian timezones", () => {
    expect(ianaToRailsTimezone("Asia/Tokyo")).toBe("Osaka")
    expect(ianaToRailsTimezone("Asia/Shanghai")).toBe("Beijing")
    expect(ianaToRailsTimezone("Asia/Kolkata")).toBe("Chennai")
  })

  it("maps Pacific timezones", () => {
    expect(ianaToRailsTimezone("Pacific/Auckland")).toBe("Auckland")
    expect(ianaToRailsTimezone("Pacific/Honolulu")).toBe("Hawaii")
  })

  it("maps UTC", () => {
    expect(ianaToRailsTimezone("Etc/UTC")).toBe("UTC")
  })

  it("returns null for unknown IANA timezone", () => {
    expect(ianaToRailsTimezone("Mars/Olympus_Mons")).toBeNull()
    expect(ianaToRailsTimezone("")).toBeNull()
  })
})

describe("railsToIanaTimezone", () => {
  it("maps Rails timezone names to IANA identifiers", () => {
    expect(railsToIanaTimezone("Pacific Time (US & Canada)")).toBe("America/Los_Angeles")
    expect(railsToIanaTimezone("Eastern Time (US & Canada)")).toBe("America/New_York")
    expect(railsToIanaTimezone("UTC")).toBe("Etc/UTC")
  })

  it("returns null for unknown Rails timezone", () => {
    expect(railsToIanaTimezone("Nonexistent")).toBeNull()
    expect(railsToIanaTimezone("")).toBeNull()
  })
})

describe("parseDatetimeInTimezone", () => {
  it("parses a datetime-local value in Pacific time correctly", () => {
    // 2026-04-29T22:05 Pacific = 2026-04-30T05:05 UTC (PDT = UTC-7)
    const result = parseDatetimeInTimezone("2026-04-29T22:05", "Pacific Time (US & Canada)")
    const utcHours = result.getUTCHours()
    const utcDate = result.getUTCDate()

    // Should be April 30 at 05:05 UTC
    expect(utcDate).toBe(30)
    expect(utcHours).toBe(5)
    expect(result.getUTCMinutes()).toBe(5)
  })

  it("parses a datetime-local value in UTC correctly", () => {
    const result = parseDatetimeInTimezone("2026-04-29T14:30", "UTC")
    expect(result.getUTCHours()).toBe(14)
    expect(result.getUTCMinutes()).toBe(30)
    expect(result.getUTCDate()).toBe(29)
  })

  it("parses a datetime-local value in Eastern time correctly", () => {
    // 2026-04-29T10:00 Eastern = 2026-04-29T14:00 UTC (EDT = UTC-4)
    const result = parseDatetimeInTimezone("2026-04-29T10:00", "Eastern Time (US & Canada)")
    expect(result.getUTCHours()).toBe(14)
    expect(result.getUTCMinutes()).toBe(0)
  })

  it("falls back to local time for unknown timezone", () => {
    const result = parseDatetimeInTimezone("2026-04-29T14:30", "Nonexistent Timezone")
    // Should parse as browser local time (same as new Date("2026-04-29T14:30"))
    const expected = new Date("2026-04-29T14:30")
    expect(result.getTime()).toBe(expected.getTime())
  })

  it("returns NaN date for invalid datetime string", () => {
    const result = parseDatetimeInTimezone("not-a-date", "UTC")
    expect(isNaN(result.getTime())).toBe(true)
  })
})
