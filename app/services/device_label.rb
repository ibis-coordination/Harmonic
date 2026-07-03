# typed: true

# Parses a human-readable device label ("iPhone · Safari") from a User-Agent
# string. Used wherever a per-device row is shown to users (trusted devices,
# push subscriptions).
module DeviceLabel
  extend T::Sig

  sig { params(ua: T.nilable(String)).returns(String) }
  def self.parse(ua)
    return "Unknown device" if ua.blank?

    parts = [parse_platform(ua), parse_browser(ua)].compact
    parts.empty? ? "Unknown device" : parts.join(" · ")
  end

  sig { params(ua: String).returns(T.nilable(String)) }
  def self.parse_platform(ua)
    case ua
    when /iPhone/i then "iPhone"
    when /iPad/i then "iPad"
    when /Android/i then "Android"
    when /Macintosh|Mac OS X/i then "Mac"
    when /Windows/i then "Windows PC"
    when /Linux/i then "Linux"
    end
  end

  # Order matters: Edge UA contains "Chrome", Opera UA contains "Chrome",
  # Chrome UA contains "Safari" — narrowest matches first.
  sig { params(ua: String).returns(T.nilable(String)) }
  def self.parse_browser(ua)
    case ua
    when %r{Edg/}i then "Edge"
    when %r{OPR/}i then "Opera"
    when %r{Firefox/}i then "Firefox"
    when %r{Chrome/}i then "Chrome"
    when %r{Safari/}i then "Safari"
    end
  end

  private_class_method :parse_platform, :parse_browser
end
