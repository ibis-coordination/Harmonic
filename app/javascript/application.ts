// Main application entry point
import "@hotwired/turbo-rails"
import "./controllers"
import "./polling_trigger_event"
// image_cropper functionality is now in controllers/image_cropper_controller.ts
import "./password_reset_form"
import { registerServiceWorker } from "./pwa/register"
import { wirePushResync } from "./pwa/resync"

registerServiceWorker()
wirePushResync()
