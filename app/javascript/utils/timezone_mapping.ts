// Reverse mapping of ActiveSupport::TimeZone::MAPPING
// Maps IANA timezone identifiers to Rails timezone names
// Generated from: ActiveSupport::TimeZone::MAPPING (Rails 7.2)
const IANA_TO_RAILS: Record<string, string> = {
  "Africa/Algiers": "West Central Africa",
  "Africa/Cairo": "Cairo",
  "Africa/Casablanca": "Casablanca",
  "Africa/Harare": "Harare",
  "Africa/Johannesburg": "Pretoria",
  "Africa/Monrovia": "Monrovia",
  "Africa/Nairobi": "Nairobi",
  "America/Argentina/Buenos_Aires": "Buenos Aires",
  "America/Bogota": "Bogota",
  "America/Caracas": "Caracas",
  "America/Chicago": "Central Time (US & Canada)",
  "America/Chihuahua": "Chihuahua",
  "America/Denver": "Mountain Time (US & Canada)",
  "America/Godthab": "Greenland",
  "America/Guatemala": "Central America",
  "America/Guyana": "Georgetown",
  "America/Halifax": "Atlantic Time (Canada)",
  "America/Indiana/Indianapolis": "Indiana (East)",
  "America/Juneau": "Alaska",
  "America/La_Paz": "La Paz",
  "America/Lima": "Lima",
  "America/Los_Angeles": "Pacific Time (US & Canada)",
  "America/Mazatlan": "Mazatlan",
  "America/Mexico_City": "Guadalajara",
  "America/Monterrey": "Monterrey",
  "America/Montevideo": "Montevideo",
  "America/New_York": "Eastern Time (US & Canada)",
  "America/Phoenix": "Arizona",
  "America/Puerto_Rico": "Puerto Rico",
  "America/Regina": "Saskatchewan",
  "America/Santiago": "Santiago",
  "America/Sao_Paulo": "Brasilia",
  "America/St_Johns": "Newfoundland",
  "America/Tijuana": "Tijuana",
  "Asia/Almaty": "Almaty",
  "Asia/Baghdad": "Baghdad",
  "Asia/Baku": "Baku",
  "Asia/Bangkok": "Bangkok",
  "Asia/Chongqing": "Chongqing",
  "Asia/Colombo": "Sri Jayawardenepura",
  "Asia/Dhaka": "Dhaka",
  "Asia/Hong_Kong": "Hong Kong",
  "Asia/Irkutsk": "Irkutsk",
  "Asia/Jakarta": "Jakarta",
  "Asia/Jerusalem": "Jerusalem",
  "Asia/Kabul": "Kabul",
  "Asia/Kamchatka": "Kamchatka",
  "Asia/Karachi": "Islamabad",
  "Asia/Kathmandu": "Kathmandu",
  "Asia/Kolkata": "Chennai",
  "Asia/Krasnoyarsk": "Krasnoyarsk",
  "Asia/Kuala_Lumpur": "Kuala Lumpur",
  "Asia/Kuwait": "Kuwait",
  "Asia/Magadan": "Magadan",
  "Asia/Muscat": "Abu Dhabi",
  "Asia/Novosibirsk": "Novosibirsk",
  "Asia/Rangoon": "Rangoon",
  "Asia/Riyadh": "Riyadh",
  "Asia/Seoul": "Seoul",
  "Asia/Shanghai": "Beijing",
  "Asia/Singapore": "Singapore",
  "Asia/Srednekolymsk": "Srednekolymsk",
  "Asia/Taipei": "Taipei",
  "Asia/Tashkent": "Tashkent",
  "Asia/Tbilisi": "Tbilisi",
  "Asia/Tehran": "Tehran",
  "Asia/Tokyo": "Osaka",
  "Asia/Ulaanbaatar": "Ulaanbaatar",
  "Asia/Urumqi": "Urumqi",
  "Asia/Vladivostok": "Vladivostok",
  "Asia/Yakutsk": "Yakutsk",
  "Asia/Yekaterinburg": "Ekaterinburg",
  "Asia/Yerevan": "Yerevan",
  "Atlantic/Azores": "Azores",
  "Atlantic/Cape_Verde": "Cape Verde Is.",
  "Atlantic/South_Georgia": "Mid-Atlantic",
  "Australia/Adelaide": "Adelaide",
  "Australia/Brisbane": "Brisbane",
  "Australia/Canberra": "Canberra",
  "Australia/Darwin": "Darwin",
  "Australia/Hobart": "Hobart",
  "Australia/Melbourne": "Melbourne",
  "Australia/Perth": "Perth",
  "Australia/Sydney": "Sydney",
  "Etc/GMT+12": "International Date Line West",
  "Etc/UTC": "UTC",
  "Europe/Amsterdam": "Amsterdam",
  "Europe/Athens": "Athens",
  "Europe/Belgrade": "Belgrade",
  "Europe/Berlin": "Berlin",
  "Europe/Bratislava": "Bratislava",
  "Europe/Brussels": "Brussels",
  "Europe/Bucharest": "Bucharest",
  "Europe/Budapest": "Budapest",
  "Europe/Copenhagen": "Copenhagen",
  "Europe/Dublin": "Dublin",
  "Europe/Helsinki": "Helsinki",
  "Europe/Istanbul": "Istanbul",
  "Europe/Kaliningrad": "Kaliningrad",
  "Europe/Kiev": "Kyiv",
  "Europe/Lisbon": "Lisbon",
  "Europe/Ljubljana": "Ljubljana",
  "Europe/London": "Edinburgh",
  "Europe/Madrid": "Madrid",
  "Europe/Minsk": "Minsk",
  "Europe/Moscow": "Moscow",
  "Europe/Paris": "Paris",
  "Europe/Prague": "Prague",
  "Europe/Riga": "Riga",
  "Europe/Rome": "Rome",
  "Europe/Samara": "Samara",
  "Europe/Sarajevo": "Sarajevo",
  "Europe/Skopje": "Skopje",
  "Europe/Sofia": "Sofia",
  "Europe/Stockholm": "Stockholm",
  "Europe/Tallinn": "Tallinn",
  "Europe/Vienna": "Vienna",
  "Europe/Vilnius": "Vilnius",
  "Europe/Volgograd": "Volgograd",
  "Europe/Warsaw": "Warsaw",
  "Europe/Zagreb": "Zagreb",
  "Europe/Zurich": "Bern",
  "Pacific/Apia": "Samoa",
  "Pacific/Auckland": "Auckland",
  "Pacific/Chatham": "Chatham Is.",
  "Pacific/Fakaofo": "Tokelau Is.",
  "Pacific/Fiji": "Fiji",
  "Pacific/Guadalcanal": "Solomon Is.",
  "Pacific/Guam": "Guam",
  "Pacific/Honolulu": "Hawaii",
  "Pacific/Majuro": "Marshall Is.",
  "Pacific/Midway": "Midway Island",
  "Pacific/Noumea": "New Caledonia",
  "Pacific/Pago_Pago": "American Samoa",
  "Pacific/Port_Moresby": "Port Moresby",
  "Pacific/Tongatapu": "Nuku'alofa",
}

// Reverse mapping: Rails timezone names to IANA identifiers
const RAILS_TO_IANA: Record<string, string> = Object.fromEntries(
  Object.entries(IANA_TO_RAILS).map(([iana, rails]) => [rails, iana])
)

/**
 * Maps an IANA timezone identifier (from the browser) to a Rails timezone name
 * (used by time_zone_select). Returns null if no mapping exists.
 */
export function ianaToRailsTimezone(iana: string): string | null {
  if (!iana) return null
  return IANA_TO_RAILS[iana] ?? null
}

/**
 * Maps a Rails timezone name to an IANA timezone identifier.
 * Returns null if no mapping exists.
 */
export function railsToIanaTimezone(rails: string): string | null {
  if (!rails) return null
  return RAILS_TO_IANA[rails] ?? null
}

/**
 * Parses a datetime-local string (e.g. "2026-04-29T22:05") in a specific
 * Rails timezone and returns a Date object representing that moment in UTC.
 * Falls back to browser local time if timezone can't be resolved.
 */
export function parseDatetimeInTimezone(datetimeLocal: string, railsTimezone: string): Date {
  const iana = railsToIanaTimezone(railsTimezone)
  if (!iana) return new Date(datetimeLocal)

  // Build an ISO-ish string and use the Intl API to find the UTC offset
  // for this specific datetime in this timezone
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone: iana,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
    timeZoneName: "shortOffset",
  })

  // Parse the datetime-local as if it were in the target timezone by computing
  // the offset. We create a date in local time first, then adjust.
  const localDate = new Date(datetimeLocal)
  if (isNaN(localDate.getTime())) return localDate

  // Format a known date in the target timezone to extract the offset
  const parts = formatter.formatToParts(localDate)
  const tzPart = parts.find((p) => p.type === "timeZoneName")
  if (!tzPart) return localDate

  // Parse offset like "GMT-7", "GMT+5:30", "GMT+0", or bare "GMT" (= UTC)
  const offsetMatch = tzPart.value.match(/GMT([+-]?)(\d+)?(?::(\d+))?/)
  if (!offsetMatch) return localDate

  const sign = offsetMatch[1] === "-" ? -1 : 1
  const hours = parseInt(offsetMatch[2] || "0", 10)
  const minutes = parseInt(offsetMatch[3] || "0", 10)
  const targetOffsetMs = sign * (hours * 60 + minutes) * 60_000

  // Browser's local offset for this date
  const localOffsetMs = -localDate.getTimezoneOffset() * 60_000

  // Adjust: the datetime-local value was interpreted as browser local time,
  // but we want it in the target timezone
  return new Date(localDate.getTime() - targetOffsetMs + localOffsetMs)
}
