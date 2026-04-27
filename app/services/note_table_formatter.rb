# typed: true

class NoteTableFormatter
  extend T::Sig

  sig { params(table_data: T::Hash[String, T.untyped]).returns(String) }
  def self.to_markdown(table_data)
    parts = []

    description = table_data["description"]
    parts << sanitize(description.to_s).strip << "\n" if description.present?

    columns = table_data["columns"] || []
    rows = table_data["rows"] || []

    return parts.join if columns.empty?

    col_names = columns.map { |c| escape_pipe(sanitize(c["name"].to_s)) }

    parts << "| #{col_names.join(' | ')} |"
    parts << "| #{col_names.map { |_| '---' }.join(' | ')} |"

    rows.each do |row|
      cells = columns.map { |c| escape_pipe(sanitize(row[c["name"]].to_s)) }
      parts << "| #{cells.join(' | ')} |"
    end

    parts.join("\n")
  end

  sig { params(value: String).returns(String) }
  def self.escape_pipe(value)
    value.gsub("|", "\\|")
  end

  sig { params(value: String).returns(String) }
  def self.sanitize(value)
    value.delete("\x00").gsub(/[\x01-\x08\x0B\x0C\x0E-\x1F]/, "")
  end
end
