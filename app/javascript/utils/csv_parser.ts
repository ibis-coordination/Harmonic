export interface CsvParseResult {
  headers: string[]
  rows: Record<string, string>[]
  errors: string[]
}

/**
 * Parses a CSV string into headers and row objects.
 * Handles quoted fields (including commas and newlines within quotes),
 * trims whitespace from headers, and skips empty rows.
 */
export function parseCsv(input: string): CsvParseResult {
  const errors: string[] = []

  if (!input.trim()) {
    return { headers: [], rows: [], errors: ["CSV input is empty"] }
  }

  const lines = splitCsvLines(input)

  if (lines.length === 0) {
    return { headers: [], rows: [], errors: ["CSV input is empty"] }
  }

  const headers = parseCsvRow(lines[0]).map((h) => h.trim())

  if (headers.length === 0 || headers.every((h) => h === "")) {
    return { headers: [], rows: [], errors: ["No column headers found in first row"] }
  }

  const duplicates = headers.filter((h, i) => h !== "" && headers.indexOf(h) !== i)
  if (duplicates.length > 0) {
    errors.push(`Duplicate column names: ${[...new Set(duplicates)].join(", ")}`)
  }

  const rows: Record<string, string>[] = []

  for (let i = 1; i < lines.length; i++) {
    const values = parseCsvRow(lines[i])

    // Skip empty rows
    if (values.every((v) => v.trim() === "")) continue

    const row: Record<string, string> = {}
    headers.forEach((header, idx) => {
      if (header !== "") {
        row[header] = idx < values.length ? values[idx] : ""
      }
    })
    rows.push(row)
  }

  return { headers: headers.filter((h) => h !== ""), rows, errors }
}

/**
 * Splits CSV input into lines, respecting quoted fields that contain newlines.
 */
function splitCsvLines(input: string): string[] {
  const lines: string[] = []
  let current = ""
  let inQuotes = false

  for (let i = 0; i < input.length; i++) {
    const char = input[i]

    if (char === '"') {
      if (inQuotes && input[i + 1] === '"') {
        current += '""'
        i++ // skip escaped quote, but preserve both chars for parseCsvRow
      } else {
        inQuotes = !inQuotes
        current += char
      }
    } else if ((char === "\n" || char === "\r") && !inQuotes) {
      if (char === "\r" && input[i + 1] === "\n") i++ // skip \r\n
      if (current.trim() !== "") lines.push(current)
      current = ""
    } else {
      current += char
    }
  }

  if (current.trim() !== "") lines.push(current)

  return lines
}

/**
 * Parses a single CSV row into an array of field values.
 * Handles quoted fields with commas and escaped quotes.
 */
function parseCsvRow(line: string): string[] {
  const fields: string[] = []
  let current = ""
  let inQuotes = false

  for (let i = 0; i < line.length; i++) {
    const char = line[i]

    if (char === '"') {
      if (inQuotes && line[i + 1] === '"') {
        current += '"'
        i++
      } else {
        inQuotes = !inQuotes
      }
    } else if (char === "," && !inQuotes) {
      fields.push(current)
      current = ""
    } else {
      current += char
    }
  }

  fields.push(current)
  return fields
}
