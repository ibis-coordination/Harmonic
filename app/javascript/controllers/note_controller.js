import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["confirmButton", "confirmButtonMessage", "confirmSection",
                    "historyLog"];

  connect() {
    // console.log("Connected to note controller");
    // ["confirmButton", "confirmButtonMessage", "confirmSection",].forEach((target) => {
    //   console.log(`Target ${target}:`, this[target]);
    // })
  }

  get csrfToken() {
    return document.querySelector("meta[name='csrf-token']").content;
  }

  async confirm(event) {
    event.preventDefault();
    if (this.editingName) return;
    // console.log("Confirming read... " + this.confirmButtonTarget.dataset.url);
    this.confirmButtonTarget.innerHTML = "Confirming...";
    const url = this.confirmButtonTarget.dataset.url;
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken,
        },
        body: JSON.stringify({
          confirmed: true,
        }),
      });
      const html = await response.text();
      this.confirmButtonTarget.remove();
      this.confirmSectionTarget.innerHTML = html;
      // this.refreshHistoryLog(event);
      const mc = new Event('metricChange');
      document.dispatchEvent(mc);
    } catch (error) {
      console.error("Error confirming read:", error);
      this.confirmSectionTarget.innerHTML = "Something went wrong. Please refresh the page and try again.";
    }
  }

  confirmButtonMouseEnter(event) {
    if (this.editingName) return;
    this.confirmButtonMessageTarget.style.textDecoration = "underline";
  }

  confirmButtonMouseLeave(event) {
    this.confirmButtonMessageTarget.style.textDecoration = null;
  }

  // async refreshHistoryLog(event) {
  //   event.preventDefault();
  //   const url = this.historyLogTarget.dataset.url;
  //   try {
  //     const response = await fetch(url);
  //     const html = await response.text();
  //     this.historyLogTarget.innerHTML = html;
  //   } catch (error) {
  //     console.error("Error showing more history:", error);
  //   }
  // }

  async refreshDisplay(event) {
    event.preventDefault()
    if (this.refreshing) return;
    this.refreshing = true;
    this.refreshing = false;
  }

}
