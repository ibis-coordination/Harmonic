# Harmonic UI/UX Review

**Date:** January 23, 2026
**Reviewer:** Claude (AI UI/UX Designer)
**Screenshots:** `.playwright-mcp/ui-review/`

---

## Executive Summary

The Harmonic application has a clean, functional UI with a GitHub-inspired design system. The interface prioritizes content readability and follows a consistent heading-based form pattern. However, there are several areas where the user experience could be improved through better visual hierarchy, consistency, and polish.

**Overall Grade: B-**

### Strengths
- Clean, readable typography
- Consistent breadcrumb navigation pattern
- Good use of iconography (Octicons)
- Clear visual distinction between public/private content
- Responsive form inputs

### Areas for Improvement
- Visual hierarchy needs work on several pages
- Empty states feel sparse
- Form layouts could be more consistent
- Some pages lack visual interest
- Settings pages are text-heavy

---

## Detailed Analysis

### 1. Login Page

**Screenshot:** `15-login-page.png`

#### Positive
- Clean, centered card layout
- Clear visual hierarchy with the "Log in to Harmonic" heading
- Good separation between email/password login and OAuth options
- Helpful "Forgot password?" link positioned near the password field
- Recognizable GitHub OAuth button with icon

#### Issues
- **Missing autocomplete attributes**: Console warning indicates inputs need `autocomplete` attributes for better browser integration
- **Input field sizing**: Email and password fields could benefit from more generous padding
- **"or" separator**: The plain text "or" between login methods feels minimal; a more styled divider would improve the visual separation
- **No loading state visible**: Users need feedback when submitting

#### Recommendations
1. Add `autocomplete="email"` and `autocomplete="current-password"` attributes
2. Consider adding subtle hover/focus transitions to form elements
3. Style the "or" separator with lines (e.g., `─── or ───`)

---

### 2. Home Page (Dashboard)

**Screenshot:** `01-home-page.png`

#### Positive
- Clear sectioning with "Your Scenes" and "Your Studios" headings
- Action buttons (New Scene, New Studio) are prominently placed
- Good use of icons to differentiate content types
- Footer motto adds personality

#### Issues
- **Visual monotony**: The page is very text-heavy with little visual variation
- **Empty state for Studios**: "No studios yet." feels abrupt and unhelpful
- **Other Subdomains section**: May confuse new users; purpose isn't immediately clear
- **Heading hierarchy**: Using `<code>` tags for "app" in headings creates visual noise
- **Heartbeat indicator**: The warning icon for "heartbeats not yet sent" lacks context

#### Recommendations
1. Add illustrations or larger icons for empty states
2. Provide actionable guidance in empty states (e.g., "Create your first studio to get started")
3. Consider hiding "Other Subdomains" section for users with only one subdomain
4. Add subtle background colors or cards to differentiate sections

---

### 3. Scenes List Page

**Screenshot:** `02-scenes-list.png`

#### Positive
- Consistent breadcrumb pattern
- Clean heading with icon

#### Issues
- **Extremely sparse**: Empty list shows nothing but the heading
- **No empty state guidance**: Users see no indication of what scenes are or how to create one
- **No "New Scene" button**: Users must go back to home to create a scene
- **Footer floats too high**: Large empty space above footer

#### Recommendations
1. Add "New Scene" button on this page
2. Create an informative empty state with illustration and call-to-action
3. Add description text explaining what scenes are

---

### 4. New Scene Form

**Screenshot:** `03-new-scene-form.png`

#### Positive
- Clear heading-based form structure
- Good inline validation preview for handle URL
- Helpful explanatory text for each field
- Clean radio button grouping for "Who can join?"

#### Issues
- **"That handle is already taken" message**: Shows by default even when field is empty (should only appear after validation fails)
- **No visual indication of required fields**: Users don't know what's mandatory
- **Radio button styling**: Default browser styling; could be more polished
- **Fieldset border**: The border around radio options feels dated

#### Recommendations
1. Hide the "already taken" message until validation actually fails
2. Add asterisks or "(required)" indicators to mandatory fields
3. Style the fieldset with modern card-like appearance
4. Add character count for name field if there's a limit

---

### 5. New Studio Form

**Screenshot:** `04-new-studio-form.png`

#### Positive
- Comprehensive form with all necessary options
- Good grouping of related settings
- Timezone dropdown includes many options
- Helpful explanatory text throughout

#### Issues
- **Long form**: Many fields may overwhelm users; could benefit from sections/steps
- **Same "already taken" issue** as Scene form
- **Timezone defaults to wrong value**: Shows International Date Line West instead of detecting user's timezone
- **Radio button styling**: Same dated fieldset styling as Scene form
- **No progress indicator**: Long form without sense of progress

#### Recommendations
1. Auto-detect user's timezone as default
2. Consider multi-step wizard for this form
3. Group related fields with visual separators or collapsible sections
4. Add form validation feedback before submission

---

### 6. Notifications Page

**Screenshot:** `05-notifications.png`

#### Positive
- Clean, minimal interface
- "Schedule Reminder" action is accessible
- "All caught up!" message is friendly

#### Issues
- **Very sparse**: Empty state provides no context about what notifications are
- **No navigation to notification settings**: Users can't configure notification preferences
- **Breadcrumb inconsistency**: Uses icon inline with path differently than other pages

#### Recommendations
1. Add brief description of what appears here
2. Link to notification preferences/settings
3. Consider showing recent notification history even when all are read

---

### 7. New Reminder Form

**Screenshot:** `06-new-reminder-form.png`

#### Positive
- Clean heading-based form structure (fixed from previous session)
- Good field grouping with datetime and timezone inline
- Helpful hint text for relative time syntax
- Optional fields clearly marked

#### Issues
- **Timezone dropdown very wide**: Takes up significant horizontal space
- **No validation feedback**: Users don't see if title is too long until submission
- **Relative time hint**: Useful but could be more prominent or have examples inline

#### Recommendations
1. Consider making timezone a separate row or smaller dropdown
2. Add real-time validation for required fields
3. Add a "quick set" option for common reminder times (1 hour, tomorrow, next week)

---

### 8. User Profile Page

**Screenshot:** `08-user-profile.png`

#### Positive
- Clean layout
- Handle is clearly displayed

#### Issues
- **Extremely minimal**: Shows almost no information about the user
- **Placeholder image**: The broken image icon is not user-friendly
- **No activity or history**: Profile feels incomplete
- **No actions available**: Can't edit from this page directly

#### Recommendations
1. Use a proper default avatar (initials or generated avatar)
2. Add user's recent activity or contribution summary
3. Add "Edit Profile" link
4. Show user's memberships or roles

---

### 9. User Settings Page

**Screenshot:** `09-settings-page.png`

#### Positive
- Comprehensive settings options
- Good section organization (Profile, UI Version, API Tokens, etc.)
- Toggle buttons for UI version are clear

#### Issues
- **Dense text**: Many sections with explanatory paragraphs
- **Image upload UX**: "Click image to upload" isn't obvious; no upload button
- **No section navigation**: Long page requires scrolling
- **API section empty state**: "Create API Token" with no list feels bare
- **AI Agents section**: Complex concept with minimal explanation

#### Recommendations
1. Add sidebar navigation for settings sections
2. Add a visible "Upload Image" button alongside the image
3. Use collapsible sections for less-used features
4. Add tooltips or expandable help for complex features like AI Agents

---

### 10. Studio Home Page

**Screenshot:** `10-studio-home.png`

#### Positive
- Welcome banner is helpful for new studios
- Clear cycle-based organization
- Collapsible sections for different time periods
- Good visual hierarchy with cycle dates

#### Issues
- **Information overload**: Many sections, counters, and nested items
- **"Send a Heartbeat" button**: Unclear purpose without context
- **Countdown timer**: Meaning isn't immediately clear
- **Faded/grayed text**: Some text appears too light to read easily
- **Empty sections everywhere**: Multiple "0 unread, 0 read" indicators feel repetitive

#### Recommendations
1. Hide empty sections or collapse them by default
2. Add onboarding tooltips explaining Heartbeats and cycles
3. Improve contrast on muted text
4. Consider a "Quick Start" guide for new studios

---

### 11. New Note Form

**Screenshot:** `11-new-note-form.png`

#### Positive
- Very clean, minimal interface
- Textarea is appropriately sized
- Privacy indicator is helpful
- @ mention hint in placeholder

#### Issues
- **No formatting toolbar**: Users can't easily add markdown formatting
- **No preview**: Can't see how markdown will render
- **Welcome banner**: Still showing after navigating to new note (should dismiss contextually)
- **File attachment**: Not visible (mentioned in code but not apparent in UI)

#### Recommendations
1. Add a simple formatting toolbar or markdown cheatsheet link
2. Add a preview tab or live preview
3. Ensure file attachment UI is visible if feature exists
4. Auto-dismiss welcome banner after first action

---

### 12. New Decision Form

**Screenshot:** `12-new-decision-form.png`

#### Positive
- Clear separation of question and description fields
- Good deadline options with flexibility
- Privacy indicator present

#### Issues
- **No heading for main fields**: "Question" and "Description" aren't labeled with headings like other forms
- **Options section**: Only shows dropdown for who can add options, not the actual options interface
- **Datetime input styling**: Default browser styling looks inconsistent
- **Timezone display**: "(GMT-12:00) International Date Line West" is verbose

#### Recommendations
1. Add h3 headings for Question and Description to match form pattern
2. Abbreviate timezone display
3. Add inline help explaining what "Options" means in this context
4. Consider datetime picker library for better UX

---

### 13. New Commitment Form

**Screenshot:** `13-new-commitment-form.png`

#### Positive
- Similar structure to Decision form (consistency)
- "Critical Mass" concept is interesting
- Multiple deadline options

#### Issues
- **"Critical Mass" terminology**: May confuse users unfamiliar with the concept
- **Same form inconsistencies** as Decision form
- **No explanation of commitment lifecycle**: When does it "take effect"?

#### Recommendations
1. Add tooltip or help text explaining "Critical Mass"
2. Include a brief workflow explanation
3. Add h3 headings for main fields

---

### 14. Studio Settings Page

**Screenshot:** `14-studio-settings.png`

#### Positive
- Comprehensive settings
- Good grouping with h2 headings
- Features section with checkboxes is clear

#### Issues
- **Very long page**: Requires significant scrolling
- **No section navigation**: Hard to find specific settings
- **Fieldset borders**: Dated styling for radio groups
- **Same image upload UX issue** as user settings
- **Timezone selector**: Shows disabled separator option "-------------"

#### Recommendations
1. Add sticky sidebar navigation
2. Group into collapsible sections
3. Remove or hide the disabled separator option in timezone dropdown
4. Improve radio button grouping styling

---

## Cross-Cutting Issues

### 1. Inconsistent Form Patterns

Forms vary between:
- Heading-based labels (h3) with `<p>` content → Studio/Scene creation
- Inline labels → Some settings forms
- No labels, just placeholders → Note/Decision/Commitment forms

**Recommendation:** Standardize on heading-based pattern for all forms

### 2. Empty States

Most empty states are:
- Text-only with no visual interest
- Missing clear calls-to-action
- Not explaining what would appear there

**Recommendation:** Create a consistent empty state component with illustration, message, and action button

### 3. Visual Hierarchy

Issues across pages:
- Heavy use of default browser styling for form elements
- Limited use of color beyond links
- Inconsistent spacing between sections

**Recommendation:** Develop a spacing scale and apply consistently; add subtle background variations

### 4. Mobile Responsiveness

Not tested in this review, but several patterns suggest potential issues:
- Wide form inputs
- Inline datetime + timezone fields
- Long dropdowns

**Recommendation:** Conduct mobile-specific testing

### 5. Accessibility

Positive observations:
- Good use of semantic headings
- Icons have accompanying text in most cases
- Form inputs have visible labels

Areas to verify:
- Focus states on all interactive elements
- Color contrast ratios
- Screen reader testing

---

## Priority Recommendations

### High Priority (User Impact)
1. Fix timezone default to detect user's timezone
2. Hide "already taken" message until validation fails
3. Improve empty states with illustrations and CTAs
4. Add required field indicators to forms

### Medium Priority (Polish)
5. Standardize form patterns across all forms
6. Add section navigation to long settings pages
7. Improve radio button and fieldset styling
8. Create proper default avatars for users/studios

### Low Priority (Nice to Have)
9. Add markdown preview to text areas
10. Implement form progress indicators for long forms
11. Add subtle animations and transitions
12. Create onboarding tooltips for complex features

---

## Appendix: Screenshots Index

| # | Page | File |
|---|------|------|
| 1 | Home/Dashboard | `01-home-page.png` |
| 2 | Scenes List | `02-scenes-list.png` |
| 3 | New Scene Form | `03-new-scene-form.png` |
| 4 | New Studio Form | `04-new-studio-form.png` |
| 5 | Notifications | `05-notifications.png` |
| 6 | New Reminder Form | `06-new-reminder-form.png` |
| 7 | User Dropdown Menu | `07-user-dropdown-menu.png` |
| 8 | User Profile | `08-user-profile.png` |
| 9 | User Settings | `09-settings-page.png` |
| 10 | Studio Home | `10-studio-home.png` |
| 11 | New Note Form | `11-new-note-form.png` |
| 12 | New Decision Form | `12-new-decision-form.png` |
| 13 | New Commitment Form | `13-new-commitment-form.png` |
| 14 | Studio Settings | `14-studio-settings.png` |
| 15 | Login Page | `15-login-page.png` |
