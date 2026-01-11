# File Uploads - Functional Gaps

**Status: COMPLETED**

File attachment functionality for the markdown API. This should be implemented as a **final, standalone step** after other functional parity work is complete.

[← Back to Index](INDEX.md)

---

## Completion Summary

Phase 4 (File Attachments) has been completed with the following:

### Implemented Features

1. **Attachments display in markdown views:**
   - Notes, Decisions, and Commitments show their attachments
   - Attachments section shows filename, size, and content type
   - Links to download each attachment

2. **Markdown API actions:**
   - `add_attachment(file)` - Add attachment via base64 encoded file data
   - `remove_attachment()` - Remove an existing attachment

3. **API Format:**
   - Base64 encoded JSON format chosen for simplicity
   - File parameter accepts: `{ data: base64, content_type: string, filename: string }`
   - Also supports direct file uploads for multipart form data

4. **Tests:**
   - 8 new tests covering attachment display and actions
   - Tests for Note, Decision, and Commitment attachments

### Routes Added

For Notes (`/n/:id`):
- `GET /edit/actions/add_attachment` - Describe action (requires edit permission)
- `POST /edit/actions/add_attachment` - Add attachment (requires edit permission)
- `GET /attachments/:attachment_id/actions` - Attachment actions index
- `GET /attachments/:attachment_id/actions/remove_attachment` - Describe remove
- `POST /attachments/:attachment_id/actions/remove_attachment` - Remove attachment

For Decisions (`/d/:id`) and Commitments (`/c/:id`):
- `GET /settings/actions/add_attachment` - Describe action (requires settings permission)
- `POST /settings/actions/add_attachment` - Add attachment (requires settings permission)
- `GET /attachments/:attachment_id/actions` - Attachment actions index
- `GET /attachments/:attachment_id/actions/remove_attachment` - Describe remove
- `POST /attachments/:attachment_id/actions/remove_attachment` - Remove attachment

**Note:** `add_attachment` is only available on edit/settings pages to ensure only users with edit permissions can add attachments.

---

## Scope (Original)

### Creating Content with Attachments

| Action | Current Params | Missing |
|--------|----------------|---------|
| `create_note()` | text | files (future enhancement) |
| `create_decision()` | question, options, deadline, threshold | files (future enhancement) |
| `create_commitment()` | title, description, deadline, critical_mass | files (future enhancement) |

### Viewing Attachments

| Page | Current State | Needed |
|------|---------------|--------|
| Note show | ✅ Attachments displayed | List attached files with download links |
| Decision show | ✅ Attachments displayed | List attached files with download links |
| Commitment show | ✅ Attachments displayed | List attached files with download links |

### Adding Attachments to Existing Content

| Action | Current State | Needed |
|--------|---------------|--------|
| Add attachment to note | ✅ `add_attachment()` | `add_attachment()` action |
| Add attachment to decision | ✅ `add_attachment()` | `add_attachment()` action |
| Add attachment to commitment | ✅ `add_attachment()` | `add_attachment()` action |
| Remove attachment | ✅ `remove_attachment()` | `remove_attachment()` action |

---

## Design Considerations

### API Format Options

1. **Base64 encoded in JSON**
   - Pros: Simple, works with existing action format
   - Cons: Increases payload size ~33%, memory intensive for large files

2. **Multipart form data**
   - Pros: Efficient for binary data, standard HTTP
   - Cons: Different from current action format, may need special handling

3. **Two-step upload**
   - Pros: Separates concerns, can handle large files
   - Cons: More complex, requires upload endpoint

### File Size Limits

- Current HTML UI has configurable limits per studio
- API should respect same limits
- Need error handling for oversized files

### File Types

- Current HTML UI may have type restrictions
- API should enforce same restrictions
- Need clear error messages for rejected types

---

## Implementation Notes

### Priority: Low (Final Step)

File uploads are a "nice to have" for markdown API. Most MCP/API users can:
- Create content without attachments
- Reference external files via URLs in content
- Use HTML UI for attachment-heavy workflows

### Dependencies

- All other functional parity work should be complete first
- May need infrastructure changes (storage, upload handling)
- Consider rate limiting and abuse prevention

---

## Security Measures

### Current Security (in Attachment model)

| Measure | Status | Details |
|---------|--------|---------|
| File type restriction | ✅ Active | Only `image/*`, `text/*`, `application/pdf` allowed |
| File size limit | ✅ Active | Max 10MB per file |
| Virus scanning | ✅ Active | ClamAV integration via clamby gem, scans all uploads |

### Security Improvements (Implemented)

1. **Magic byte validation** - Verify file content matches claimed content_type using file signatures
   - PNG: `89 50 4E 47 0D 0A 1A 0A`
   - JPEG: `FF D8 FF`
   - GIF: `47 49 46 38`
   - PDF: `25 50 44 46` (`%PDF`)
   - Rejects files where magic bytes don't match claimed type

2. **Filename sanitization** - Sanitize filenames before storage
   - Remove path traversal attempts (`../`, `..\\`)
   - Remove null bytes and control characters
   - Limit filename length
   - Preserve file extension

3. **Base64 payload size limit** - Limit encoded payload size at controller level
   - Max 15MB encoded (accounts for ~33% base64 overhead on 10MB file)
   - Reject before decoding to prevent memory issues

4. **ClamAV virus scanning** - Scan all uploaded files for malware
   - Uses clamby gem to connect to ClamAV daemon
   - ClamAV runs as a separate Docker service
   - Files are scanned before being accepted
   - Disabled in test environment for performance (can be enabled via mocking)

### Future Security Considerations

- **Rate limiting** - Limit upload frequency per user/API token
- **Content-Disposition headers** - Ensure downloads use `attachment` disposition

---

## Questions to Resolve

1. ~~What file upload format makes most sense for MCP clients?~~ → Base64 JSON chosen
2. Should we support viewing attachments before creating uploads?
3. ~~Are there security considerations for API file uploads vs HTML uploads?~~ → See Security Measures above
4. Do we need special handling for image attachments (thumbnails, previews)?
