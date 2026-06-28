# typed: true

class NoteTableFormatter
  extend T::Sig

  # When `include_ids` is true, a `_harmonic_row_id` column is prepended so
  # callers can discover each row's identifier (needed by update_row /
  # delete_row). This is opt-in because the human table view and the stored note
  # body should not expose the internal id; only the machine-facing query_rows
  # action uses it.
  sig { params(table_data: T::Hash[String, T.untyped], include_ids: T::Boolean).returns(String) }
  def self.to_markdown(table_data, include_ids: false)
    parts = []

    description = table_data["description"]
    parts << sanitize(description.to_s).strip << "\n" if description.present?

    columns = table_data["columns"] || []
    rows = table_data["rows"] || []

    return parts.join if columns.empty?

    col_names = columns.map { |c| escape_pipe(sanitize(c["name"].to_s)) }
    col_names.unshift("_harmonic_row_id") if include_ids

    parts << "| #{col_names.join(' | ')} |"
    parts << "| #{col_names.map { |_| '---' }.join(' | ')} |"

    rows.each do |row|
      cells = columns.map { |c| escape_pipe(sanitize(row[c["name"]].to_s)) }
      cells.unshift(escape_pipe(sanitize(row["_harmonic_row_id"].to_s))) if include_ids
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
