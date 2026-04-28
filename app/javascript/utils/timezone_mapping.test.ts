import { describe, it, expect } from "vitest"
import { ianaToRailsTimezone } from "./timezone_mapping"

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
