// Import and register all Stimulus controllers

import { Application } from "@hotwired/stimulus"

// Start Stimulus application
const application = Application.start()

// Configure Stimulus development experience
application.debug = false
// @ts-expect-error - Stimulus is attached to window for debugging
window.Stimulus = application

// Import all controllers
import AjaxToggleController from "./ajax_toggle_controller"
import AutoHideHeaderController from "./auto_hide_header_controller"
import ListFormController from "./list_form_controller"
import CardExpandController from "./card_expand_controller"
import CardNavigateController from "./card_navigate_controller"
import ClipboardController from "./clipboard_controller"
import HandleInputController from "./handle_input_controller"
import CodeBlockController from "./code_block_controller"
import CollapsableSectionController from "./collapseable_section_controller"
import CommentsController from "./comments_controller"
import CommentThreadController from "./comment_thread_controller"
import CommitmentController from "./commitment_controller"
import CooldownButtonController from "./cooldown_button_controller"
import CountdownController from "./countdown_controller"
import DatetimeInputController from "./datetime_input_controller"
import DeadlineOptionsController from "./deadline_options_controller"
import DecisionController from "./decision_controller"
import DecisionResultsController from "./decision_results_controller"
import FormTrackerController from "./form_tracker_controller"
import DecisionVotersController from "./decision_voters_controller"
import HeaderSearchController from "./header_search_controller"
import HandleAvailabilityController from "./handle_availability_controller"
import HeartbeatController from "./heartbeat_controller"
import HideOnErrorController from "./hide_on_error_controller"
import HistoryBackController from "./history_back_controller"
import HelloController from "./hello_controller"
import ImageCropperController from "./image_cropper_controller"
import LightboxController from "./lightbox_controller"
import LogoutController from "./logout_controller"
import MemberSelectController from "./member_select_controller"
import MentionAutocompleteController from "./mention_autocomplete_controller"
import MarkdownPreviewController from "./markdown_preview_controller"
import MetricController from "./metric_controller"
import MoreButtonController from "./more_button_controller"
import NavController from "./nav_controller"
import NotificationActionsController from "./notification_actions_controller"
import NotificationBadgeController from "./notification_badge_controller"
import RailBadgesController from "./rail_badges_controller"
import CsvImportController from "./csv_import_controller"
import NoteController from "./note_controller"
import NoteMediaUploaderController from "./note_media_uploader_controller"
import NoteSubtypeController from "./note_subtype_controller"
import OptionController from "./option_controller"
import PinController from "./pin_controller"
import PulseActionController from "./pulse_action_controller"
import PulseFilterController from "./pulse_filter_controller"
import RadioToggleController from "./radio_toggle_controller"
import RecoveryCodesController from "./recovery_codes_controller"
import RemoveParentController from "./remove_parent_controller"
import ScratchpadLinksController from "./scratchpad_links_controller"
import SecretRevealController from "./secret_reveal_controller"
import AgentChatController from "./agent_chat_controller"
import ChatSearchController from "./chat_search_controller"
import AiAgentManagerController from "./ai_agent_manager_controller"
import AiAgentModeController from "./ai_agent_mode_controller"
import AiAgentCollectiveAdderController from "./ai_agent_collective_adder_controller"
import TaskRunStatusController from "./task_run_status_controller"
import TimeagoController from "./timeago_controller"
import TooltipController from "./tooltip_controller"
import TopLeftMenuController from "./top_left_menu_controller"
import TopRightMenuController from "./top_right_menu_controller"
import TrioLogoController from "./trio_logo_controller"
import AuditVerifyController from "./audit_verify_controller"
import AutoSubmitController from "./auto_submit_controller"
import CheckboxGroupController from "./checkbox_group_controller"
import KebabMenuController from "./kebab_menu_controller"
import SummaryToggleController from "./summary_toggle_controller"
import CommitmentSubtypeController from "./commitment_subtype_controller"
import DecisionSubtypeController from "./decision_subtype_controller"
import DialogController from "./dialog_controller"
import TabsController from "./tabs_controller"
import WebhookTestController from "./webhook_test_controller"
import WebPushController from "./web_push_controller"

// Register all controllers
application.register("ajax-toggle", AjaxToggleController)
application.register("auto-hide-header", AutoHideHeaderController)
application.register("card-expand", CardExpandController)
application.register("card-navigate", CardNavigateController)
application.register("clipboard", ClipboardController)
application.register("handle-input", HandleInputController)
application.register("code-block", CodeBlockController)
application.register("csv-import", CsvImportController)
application.register("collapseable-section", CollapsableSectionController)
application.register("comments", CommentsController)
application.register("comment-thread", CommentThreadController)
application.register("commitment", CommitmentController)
application.register("cooldown-button", CooldownButtonController)
application.register("countdown", CountdownController)
application.register("datetime-input", DatetimeInputController)
application.register("deadline-options", DeadlineOptionsController)
application.register("decision", DecisionController)
application.register("commitment-subtype", CommitmentSubtypeController)
application.register("decision-subtype", DecisionSubtypeController)
application.register("decision-results", DecisionResultsController)
application.register("form-tracker", FormTrackerController)
application.register("decision-voters", DecisionVotersController)
application.register("header-search", HeaderSearchController)
application.register("handle-availability", HandleAvailabilityController)
application.register("heartbeat", HeartbeatController)
application.register("hello", HelloController)
application.register("hide-on-error", HideOnErrorController)
application.register("history-back", HistoryBackController)
application.register("image-cropper", ImageCropperController)
application.register("lightbox", LightboxController)
application.register("list-form", ListFormController)
application.register("logout", LogoutController)
application.register("member-select", MemberSelectController)
application.register("mention-autocomplete", MentionAutocompleteController)
application.register("markdown-preview", MarkdownPreviewController)
application.register("metric", MetricController)
application.register("more-button", MoreButtonController)
application.register("nav", NavController)
application.register("notification-actions", NotificationActionsController)
application.register("notification-badge", NotificationBadgeController)
application.register("rail-badges", RailBadgesController)
application.register("note", NoteController)
application.register("note-media-uploader", NoteMediaUploaderController)
application.register("note-subtype", NoteSubtypeController)
application.register("option", OptionController)
application.register("pin", PinController)
application.register("pulse-action", PulseActionController)
application.register("pulse-filter", PulseFilterController)
application.register("radio-toggle", RadioToggleController)
application.register("recovery-codes", RecoveryCodesController)
application.register("remove-parent", RemoveParentController)
application.register("scratchpad-links", ScratchpadLinksController)
application.register("secret-reveal", SecretRevealController)
application.register("agent-chat", AgentChatController)
application.register("chat-search", ChatSearchController)
application.register("ai_agent-manager", AiAgentManagerController)
application.register("ai_agent-mode", AiAgentModeController)
application.register("ai_agent-collective-adder", AiAgentCollectiveAdderController)
application.register("task-run-status", TaskRunStatusController)
application.register("timeago", TimeagoController)
application.register("tooltip", TooltipController)
application.register("top-left-menu", TopLeftMenuController)
application.register("top-right-menu", TopRightMenuController)
application.register("trio-logo", TrioLogoController)
application.register("audit-verify", AuditVerifyController)
application.register("auto-submit", AutoSubmitController)
application.register("checkbox-group", CheckboxGroupController)
application.register("kebab-menu", KebabMenuController)
application.register("summary-toggle", SummaryToggleController)
application.register("dialog", DialogController)
application.register("tabs", TabsController)
application.register("webhook-test", WebhookTestController)
application.register("web-push", WebPushController)

export { application }
