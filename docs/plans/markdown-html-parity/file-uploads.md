# File Uploads - Functional Gaps

File attachment functionality for the markdown API. This should be implemented as a **final, standalone step** after other functional parity work is complete.

[← Back to Index](INDEX.md)

---

## Current State

- HTML UI supports multi-file uploads on Notes, Decisions, and Commitments
- Markdown API has no file upload capability
- Existing attachments are not displayed in markdown views

---

## Scope

### Creating Content with Attachments

| Action | Current Params | Missing |
|--------|----------------|---------|
| `create_note()` | text | files |
| `create_decision()` | question, options, deadline, threshold | files |
| `create_commitment()` | title, description, deadline, critical_mass | files |

### Viewing Attachments

| Page | Current State | Needed |
|------|---------------|--------|
| Note show | Attachments not displayed | List attached files with download links |
| Decision show | Attachments not displayed | List attached files with download links |
| Commitment show | Attachments not displayed | List attached files with download links |

### Adding Attachments to Existing Content

| Action | Current State | Needed |
|--------|---------------|--------|
| Add attachment to note | Not available | `add_attachment()` action |
| Add attachment to decision | Not available | `add_attachment()` action |
| Add attachment to commitment | Not available | `add_attachment()` action |
| Remove attachment | Not available | `remove_attachment()` action |

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

## Questions to Resolve

1. What file upload format makes most sense for MCP clients?
2. Should we support viewing attachments before creating uploads?
3. Are there security considerations for API file uploads vs HTML uploads?
4. Do we need special handling for image attachments (thumbnails, previews)?
