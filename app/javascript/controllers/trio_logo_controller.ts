import { Controller } from "@hotwired/stimulus"
import { insertTrefoilLogo3D, TrefoilScene } from "../utils/trefoil_logo_3d"

/**
 * TrioLogoController renders the Trio trefoil knot logo using Three.js.
 * Renders with flat colors and bold outlines, with optional wobble animation.
 *
 * Usage:
 * <div data-controller="trio-logo"
 *      data-trio-logo-size-value="56"
 *      data-trio-logo-tube-radius-value="1.2"
 *      data-trio-logo-animate-value="true">
 * </div>
 */
export default class TrioLogoController extends Controller<HTMLElement> {
  static values = {
    size: { type: Number, default: 56 },
    tubeRadius: { type: Number, default: 0.6 },
    outlineWidth: { type: Number, default: 0.3 },
    animate: { type: Boolean, default: true },
    rotationSpeed: { type: Number, default: 0.5 },
  }

  declare sizeValue: number
  declare tubeRadiusValue: number
  declare outlineWidthValue: number
  declare animateValue: boolean
  declare rotationSpeedValue: number

  private scene: TrefoilScene | null = null

  connect(): void {
    this.render()
  }

  disconnect(): void {
    if (this.scene) {
      this.scene.dispose()
      this.scene = null
    }
  }

  render(): void {
    // Clean up previous scene if re-rendering
    if (this.scene) {
      this.scene.dispose()
      this.scene = null
    }

    // Get computed colors from CSS
    const computedStyle = getComputedStyle(this.element)
    const outlineColor = computedStyle.color || "#000000"

    // Get background color for the fill (makes the knot "pop")
    // Walk up to find a non-transparent background
    let fillColor = this.findBackgroundColor() || "#ffffff"

    this.scene = insertTrefoilLogo3D(this.element, {
      size: this.sizeValue,
      tubeRadius: this.tubeRadiusValue,
      color: fillColor,
      outlineColor: outlineColor,
      outlineWidth: this.outlineWidthValue,
      backgroundColor: "transparent",
      animate: this.animateValue,
      rotationSpeed: this.rotationSpeedValue,
    })
  }

  /**
   * Walk up the DOM to find the first non-transparent background color.
   */
  private findBackgroundColor(): string | null {
    let el: HTMLElement | null = this.element
    while (el) {
      const bg = getComputedStyle(el).backgroundColor
      // Check if it's not transparent (rgba with 0 alpha or "transparent")
      if (bg && bg !== "transparent" && bg !== "rgba(0, 0, 0, 0)") {
        return bg
      }
      el = el.parentElement
    }
    return null
  }

  sizeValueChanged(): void {
    this.render()
  }

  tubeRadiusValueChanged(): void {
    this.render()
  }

  outlineWidthValueChanged(): void {
    this.render()
  }
}
