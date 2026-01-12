// Import and register all Stimulus controllers

import { Application } from "@hotwired/stimulus"

// Start Stimulus application
const application = Application.start()

// Configure Stimulus development experience
application.debug = false
// @ts-expect-error - Stimulus is attached to window for debugging
window.Stimulus = application

// Import all controllers
import ClipboardController from "./clipboard_controller"
import CollapsableSectionController from "./collapseable_section_controller"
import CommitmentController from "./commitment_controller"
import CountdownController from "./countdown_controller"
import DeadlineOptionsController from "./deadline_options_controller"
import DecisionController from "./decision_controller"
import DecisionResultsController from "./decision_results_controller"
import DecisionVotersController from "./decision_voters_controller"
import HeartbeatController from "./heartbeat_controller"
import HelloController from "./hello_controller"
import LogoutController from "./logout_controller"
import MentionAutocompleteController from "./mention_autocomplete_controller"
import MetricController from "./metric_controller"
import MoreButtonController from "./more_button_controller"
import NavController from "./nav_controller"
import NotificationActionsController from "./notification_actions_controller"
import NotificationBadgeController from "./notification_badge_controller"
import NoteController from "./note_controller"
import OptionController from "./option_controller"
import PinController from "./pin_controller"
import ScratchpadLinksController from "./scratchpad_links_controller"
import SubagentManagerController from "./subagent_manager_controller"
import SubagentStudioAdderController from "./subagent_studio_adder_controller"
import TimeagoController from "./timeago_controller"
import TooltipController from "./tooltip_controller"
import TopLeftMenuController from "./top_left_menu_controller"
import TopRightMenuController from "./top_right_menu_controller"

// Register all controllers
application.register("clipboard", ClipboardController)
application.register("collapseable-section", CollapsableSectionController)
application.register("commitment", CommitmentController)
application.register("countdown", CountdownController)
application.register("deadline-options", DeadlineOptionsController)
application.register("decision", DecisionController)
application.register("decision-results", DecisionResultsController)
application.register("decision-voters", DecisionVotersController)
application.register("heartbeat", HeartbeatController)
application.register("hello", HelloController)
application.register("logout", LogoutController)
application.register("mention-autocomplete", MentionAutocompleteController)
application.register("metric", MetricController)
application.register("more-button", MoreButtonController)
application.register("nav", NavController)
application.register("notification-actions", NotificationActionsController)
application.register("notification-badge", NotificationBadgeController)
application.register("note", NoteController)
application.register("option", OptionController)
application.register("pin", PinController)
application.register("scratchpad-links", ScratchpadLinksController)
application.register("subagent-manager", SubagentManagerController)
application.register("subagent-studio-adder", SubagentStudioAdderController)
application.register("timeago", TimeagoController)
application.register("tooltip", TooltipController)
application.register("top-left-menu", TopLeftMenuController)
application.register("top-right-menu", TopRightMenuController)

export { application }
