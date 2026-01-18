/**
 * Generates a 3D trefoil knot logo using Three.js.
 * Uses the TrefoilKnot curve from Three.js addons for a proper trefoil shape
 * with Z-depth variation (more dimensional than TorusKnotGeometry).
 *
 * Rendered with flat colors and bold outlines (cel-shading style).
 * Supports animation with a gentle wobble effect.
 */

import * as THREE from "three"

/**
 * TrefoilKnot curve - generates a proper 3D trefoil knot with Z-depth variation.
 * Classic parametric trefoil knot formula.
 */
class TrefoilKnotCurve extends THREE.Curve<THREE.Vector3> {
  private scale: number

  constructor(scale = 1) {
    super()
    this.scale = scale
  }

  getPoint(t: number, optionalTarget = new THREE.Vector3()): THREE.Vector3 {
    const angle = t * Math.PI * 2
    const x = Math.sin(angle) + 2 * Math.sin(2 * angle)
    const y = Math.cos(angle) - 2 * Math.cos(2 * angle)
    const z = -Math.sin(3 * angle)
    return optionalTarget.set(x, y, z).multiplyScalar(this.scale)
  }
}

interface Trefoil3DOptions {
  size?: number
  tubeRadius?: number
  color?: string
  outlineColor?: string
  outlineWidth?: number
  backgroundColor?: string
  animate?: boolean
  rotationSpeed?: number
}

/**
 * Manages an animated 3D trefoil knot scene.
 */
export class TrefoilScene {
  private renderer: THREE.WebGLRenderer
  private scene: THREE.Scene
  private camera: THREE.OrthographicCamera
  private group: THREE.Group
  private animationId: number | null = null
  private rotationSpeed: number

  constructor(options: Trefoil3DOptions = {}) {
    const {
      size = 56,
      tubeRadius = 0.6,
      color = "#ffffff",
      outlineColor = "#000000",
      outlineWidth = 0.3,
      backgroundColor = "transparent",
      rotationSpeed = 0.5,
    } = options

    this.rotationSpeed = rotationSpeed

    // Create scene
    this.scene = new THREE.Scene()

    // Create camera - orthographic for consistent sizing
    // Frustum size 14 to fit the full trefoil knot with tube radius
    const frustumSize = 14
    const aspect = 1
    this.camera = new THREE.OrthographicCamera(
      (frustumSize * aspect) / -2,
      (frustumSize * aspect) / 2,
      frustumSize / 2,
      frustumSize / -2,
      0.1,
      100
    )
    this.camera.position.z = 12

    // Create renderer
    this.renderer = new THREE.WebGLRenderer({
      antialias: true,
      alpha: backgroundColor === "transparent",
    })
    this.renderer.setSize(size, size)
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))

    if (backgroundColor !== "transparent") {
      this.renderer.setClearColor(new THREE.Color(backgroundColor), 1)
    }

    // Create trefoil knot curve and geometry using TubeGeometry
    // Scale 1.5 matches the HTML example proportions
    const curve = new TrefoilKnotCurve(1.5)

    // Black outline (slightly larger tube, back-faces only)
    const outlineGeometry = new THREE.TubeGeometry(
      curve,
      200,
      tubeRadius + outlineWidth,
      32,
      true
    )
    const outlineMaterial = new THREE.MeshBasicMaterial({
      color: new THREE.Color(outlineColor),
      side: THREE.BackSide,
    })

    // White fill (front faces)
    const geometry = new THREE.TubeGeometry(curve, 200, tubeRadius, 32, true)
    const mainMaterial = new THREE.MeshBasicMaterial({
      color: new THREE.Color(color),
    })

    // Create group with meshes
    this.group = new THREE.Group()
    this.group.add(new THREE.Mesh(outlineGeometry, outlineMaterial))
    this.group.add(new THREE.Mesh(geometry, mainMaterial))
    this.scene.add(this.group)

    // Set initial rotation (no tilt - start flat like HTML example)
    this.group.rotation.x = 0
    this.group.rotation.y = 0

    // Initial render
    this.renderer.render(this.scene, this.camera)
  }

  get canvas(): HTMLCanvasElement {
    return this.renderer.domElement
  }

  startAnimation(): void {
    if (this.animationId !== null) return

    const animate = () => {
      this.animationId = requestAnimationFrame(animate)

      // Simple continuous rotation matching the HTML example
      this.group.rotation.x += 0.003 * this.rotationSpeed
      this.group.rotation.y += 0.005 * this.rotationSpeed

      this.renderer.render(this.scene, this.camera)
    }
    animate()
  }

  stopAnimation(): void {
    if (this.animationId !== null) {
      cancelAnimationFrame(this.animationId)
      this.animationId = null
    }
  }

  dispose(): void {
    this.stopAnimation()

    // Dispose of all meshes in the group
    this.group.traverse((object: THREE.Object3D) => {
      if (object instanceof THREE.Mesh) {
        object.geometry.dispose()
        if (object.material instanceof THREE.Material) {
          object.material.dispose()
        }
      }
    })

    this.renderer.dispose()
  }
}

/**
 * Create a static 3D trefoil knot canvas (no animation).
 */
export function createTrefoilCanvas(options: Trefoil3DOptions = {}): HTMLCanvasElement {
  const scene = new TrefoilScene(options)
  return scene.canvas
}

/**
 * Insert the 3D trefoil logo into a DOM element.
 * Returns the TrefoilScene for lifecycle management (animation control, disposal).
 */
export function insertTrefoilLogo3D(
  container: HTMLElement,
  options: Trefoil3DOptions = {}
): TrefoilScene {
  container.innerHTML = ""

  const scene = new TrefoilScene(options)
  const canvas = scene.canvas
  canvas.classList.add("trio-logo")
  canvas.setAttribute("aria-label", "Trio logo")
  canvas.setAttribute("role", "img")
  container.appendChild(canvas)

  if (options.animate) {
    scene.startAnimation()
  }

  return scene
}
