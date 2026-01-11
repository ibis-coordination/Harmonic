---
passing: true
last_verified: 2026-01-11
verified_by: Claude Opus 4.5
---

# Test: File Upload via Markdown API

Verifies that files can be uploaded to notes, decisions, and commitments through the markdown API using base64 encoded file data.

## Prerequisites

- Access to a studio where file uploads are enabled (both tenant and studio `allow_file_uploads` settings must be true)
- Edit permissions on the resource you want to attach files to
- For notes: any studio member can edit their own notes
- For decisions/commitments: requires settings access

## Test 1: Upload File to Note

### Steps

1. Navigate to a studio: `/studios/{studio_handle}`
2. Send a heartbeat if required
3. Create a new note: navigate to `/studios/{studio_handle}/note` and execute `create_note(text: "Test note for attachments")`
4. Navigate to the note's edit page: `/studios/{studio_handle}/n/{note_id}/edit`
5. Verify the `add_attachment(file)` action is listed
6. Execute the action with base64 encoded file data:
   ```json
   {
     "file": {
       "data": "VGhpcyBpcyBhIHRlc3QgZmlsZS4=",
       "content_type": "text/plain",
       "filename": "test-file.txt"
     }
   }
   ```
7. Navigate to the note: `/studios/{studio_handle}/n/{note_id}`
8. Verify the attachment appears in the Attachments section

### Checklist

- [x] `add_attachment(file)` action is available on note edit page
- [x] Action accepts base64 encoded file with content_type and filename
- [x] Success message shows the filename: "Attachment 'test-file.txt' added successfully"
- [x] Note show page displays attachment with filename, size, and content type
- [x] Attachment link is provided for download

## Test 2: File Type Validation

### Steps

1. Create a note and navigate to its edit page
2. Attempt to upload an executable file:
   ```json
   {
     "file": {
       "data": "TVo=",
       "content_type": "application/x-msdownload",
       "filename": "test.exe"
     }
   }
   ```
3. Verify the upload is rejected

### Checklist

- [x] Executable files (.exe) are rejected with error message
- [x] JavaScript files are rejected with error message
- [x] Only image/*, text/*, and application/pdf are accepted *(verified by automated tests)*

## Test 3: Magic Byte Validation

### Steps

1. Create a note and navigate to its edit page
2. Attempt to upload a file claiming to be PNG but with text content:
   ```json
   {
     "file": {
       "data": "VGhpcyBpcyBub3QgYSBQTkc=",
       "content_type": "image/png",
       "filename": "fake.png"
     }
   }
   ```
3. Verify the upload is rejected because magic bytes don't match

### Checklist

- [x] Files with mismatched magic bytes are rejected *(verified by automated tests)*
- [x] Error message mentions "content does not match claimed type" *(verified by automated tests)*
- [x] Valid PNG files with correct magic bytes are accepted *(verified by automated tests)*

## Test 4: File Size Limit

### Steps

1. Attempt to upload a file larger than 10MB
2. Verify the upload is rejected before the file is stored

### Checklist

- [x] Files over 10MB are rejected *(verified by automated tests)*
- [x] Base64 payloads over 15MB are rejected at controller level *(verified by automated tests)*

## Test 5: Attachment on Decision

### Prerequisites

- Settings access on a decision (creator or admin)

### Steps

1. Create a decision and navigate to its settings page: `/studios/{studio_handle}/d/{decision_id}/settings`
2. Verify `add_attachment(file)` action is listed
3. Upload a file using base64 encoded data
4. Navigate to the decision show page
5. Verify attachment is displayed

### Checklist

- [x] `add_attachment` action available on decision settings page
- [x] Attachment appears on decision show page *(verified by automated tests)*

## Test 6: Attachment on Commitment

### Prerequisites

- Settings access on a commitment (creator or admin)

### Steps

1. Create a commitment and navigate to its settings page: `/studios/{studio_handle}/c/{commitment_id}/settings`
2. Verify `add_attachment(file)` action is listed
3. Upload a file using base64 encoded data
4. Navigate to the commitment show page
5. Verify attachment is displayed

### Checklist

- [x] `add_attachment` action available on commitment settings page
- [x] Attachment appears on commitment show page *(verified by automated tests)*

## Test 7: Remove Attachment

### Steps

1. Navigate to an existing attachment's actions page: `/{resource_path}/attachments/{attachment_id}/actions`
2. Verify `remove_attachment()` action is available
3. Execute the action
4. Navigate to the parent resource
5. Verify the attachment is no longer listed

### Checklist

- [x] `remove_attachment()` action is available on attachment actions page
- [x] Successful removal shows confirmation message *(verified by automated tests)*
- [x] Attachment no longer appears on parent resource *(verified by automated tests)*

## Test 8: File Uploads Disabled

### Prerequisites

- Access to admin settings to toggle `allow_file_uploads`

### Steps

1. Disable file uploads at tenant or studio level
2. Navigate to a note's edit page
3. Verify `add_attachment` action is NOT listed

### Checklist

- [x] When tenant `allow_file_uploads` is false, action is hidden *(verified by code review)*
- [x] When studio `allow_file_uploads` is false, action is hidden *(verified by code review)*
- [x] Direct POST to add_attachment returns 403 when uploads disabled *(verified by automated tests)*

## Notes

- The MCP server `execute_action` should be called from the edit/settings page, not from the action description page (to avoid path doubling)
- Virus scanning is enabled in non-test environments when ClamAV is available
- Filename sanitization removes path traversal attempts and control characters
