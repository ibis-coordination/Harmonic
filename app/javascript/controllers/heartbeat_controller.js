import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["sendButton", "sendButtonText","heartbeatMessage","fullHeart","heartbeatsIndexLink"]

  connect() {
    this.sendButtonTarget.addEventListener("click", this.sendHeartbeat.bind(this));
    this.expandingHeart = document.getElementById('expanding-heart');
  }

  get csrfToken() {
    return document.querySelector("meta[name='csrf-token']").content;
  }

  sendHeartbeat() {
    this.animateExpandingHeart()
    const url = this.sendButtonTarget.dataset.url
    fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.csrfToken,
      },
      body: JSON.stringify({}),
    }).then(response => {
      if (response.ok) return response.json()
      throw new Error("Network response was not ok.")
    }).then(responseBody => {
      this.updateMessage(responseBody);
      this.showBlurred();
    })
  }

  animateExpandingHeart() {
    // console.log('animating heart');
    this.expandingHeart.style.display = 'block';
    this.sendButtonTarget.style.opacity = '0.8';
    this.sendButtonTarget.style.cursor = 'default';
    this.sendButtonTextTarget.textContent = "Sending Heartbeat"
    const rect = this.sendButtonTarget.getBoundingClientRect();
    this.expandingHeart.style.top = `${rect.top + window.scrollY}px`;
    this.expandingHeart.style.left = `${rect.left}px`;
    setTimeout(() => {
      this.expandingHeart.classList.add('expanded');
      setTimeout(() => {
        this.expandingHeart.style.display = 'none';
      }, 1000)
    }, 1)
  }

  updateMessage(responseBody) {
    const ohbs = responseBody.other_heartbeats;
    const cycleName = responseBody.cycle_display_name;
    this.heartbeatMessageTarget.textContent =
      `You ${ohbs > 0 ? ('+ ' + ohbs + ' other' + (ohbs == 1 ? '' : 's')) : ''} ` +
      `sent ${ohbs == 0 ? 'a ' : ''}heartbeat${ohbs > 0 ? 's' : ''} ${cycleName}.`;
    this.fullHeartTarget.style.display = 'inline';
    this.sendButtonTarget.style.display = 'none';
    // this.heartbeatsIndexLinkTarget.style.display = 'inline';
  }

  showBlurred() {
    const blurs = document.querySelectorAll('.blur-if-no-heartbeat.no-heartbeat');
    blurs.forEach((b) => b.classList.remove('no-heartbeat'));
  }
}