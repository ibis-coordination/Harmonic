import { describe, it, expect } from "vitest"
import { parseCsv } from "./csv_parser"

describe("parseCsv", () => {
  it("parses simple CSV", () => {
    const result = parseCsv("Name,Age\nAlice,30\nBob,25")

    expect(result.headers).toEqual(["Name", "Age"])
    expect(result.rows).toEqual([
      { Name: "Alice", Age: "30" },
      { Name: "Bob", Age: "25" },
    ])
    expect(result.errors).toEqual([])
  })

  it("handles quoted fields with commas", () => {
    const result = parseCsv('Name,Description\nAlice,"Likes cats, dogs"')

    expect(result.rows[0].Description).toBe("Likes cats, dogs")
  })

  it("handles quoted fields with newlines", () => {
    const result = parseCsv('Name,Bio\nAlice,"Line 1\nLine 2"')

    expect(result.rows[0].Bio).toBe("Line 1\nLine 2")
  })

  it("handles escaped quotes (double quotes)", () => {
    const result = parseCsv('Name,Quote\nAlice,"She said ""hello"""')

    expect(result.rows[0].Quote).toBe('She said "hello"')
  })

  it("trims whitespace from headers", () => {
    const result = parseCsv(" Name , Age \nAlice,30")

    expect(result.headers).toEqual(["Name", "Age"])
  })

  it("skips empty rows", () => {
    const result = parseCsv("Name,Age\nAlice,30\n\n\nBob,25\n")

    expect(result.rows.length).toBe(2)
  })

  it("handles CRLF line endings", () => {
    const result = parseCsv("Name,Age\r\nAlice,30\r\nBob,25")

    expect(result.rows.length).toBe(2)
    expect(result.rows[0].Name).toBe("Alice")
  })

  it("returns error for empty input", () => {
    const result = parseCsv("")

    expect(result.headers).toEqual([])
    expect(result.rows).toEqual([])
    expect(result.errors).toContain("CSV input is empty")
  })

  it("returns error for whitespace-only input", () => {
    const result = parseCsv("   \n  \n  ")

    expect(result.errors).toContain("CSV input is empty")
  })

  it("returns error for duplicate column names", () => {
    const result = parseCsv("Name,Name\nAlice,Bob")

    expect(result.errors.some((e) => e.includes("Duplicate"))).toBe(true)
  })

  it("handles rows with fewer columns than headers", () => {
    const result = parseCsv("A,B,C\n1")

    expect(result.rows[0]).toEqual({ A: "1", B: "", C: "" })
  })

  it("handles rows with more columns than headers (extras ignored)", () => {
    const result = parseCsv("A,B\n1,2,3,4")

    expect(result.rows[0]).toEqual({ A: "1", B: "2" })
  })

  it("handles header-only CSV (no data rows)", () => {
    const result = parseCsv("Name,Age")

    expect(result.headers).toEqual(["Name", "Age"])
    expect(result.rows).toEqual([])
    expect(result.errors).toEqual([])
  })

  it("filters out blank headers", () => {
    const result = parseCsv("Name,,Age\nAlice,,30")

    expect(result.headers).toEqual(["Name", "Age"])
    expect(result.rows[0]).toEqual({ Name: "Alice", Age: "30" })
  })
})
