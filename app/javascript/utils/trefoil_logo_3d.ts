/**
 * Generates a 3D trefoil knot logo using Three.js.
 * A trefoil knot is a (2,3) torus knot - Three.js has built-in support for this.
 *
 * Rendered with flat colors and bold outlines (cel-shading style).
 * Supports animation with a gentle wobble effect.
 */

import * as THREE from "three"

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
  private startTime: number = 0
  private rotationSpeed: number
  // View angle for the trefoil knot
  private baseRotationX: number = Math.PI / 6
  private baseRotationY: number = Math.PI / 4

  constructor(options: Trefoil3DOptions = {}) {
    const {
      size = 56,
      tubeRadius = 0.3,
      color = "#000000",
      outlineColor = "#000000",
      outlineWidth = 0.06,
      backgroundColor = "transparent",
      rotationSpeed = 0.5,
    } = options

    this.rotationSpeed = rotationSpeed

    // Create scene
    this.scene = new THREE.Scene()

    // Create camera - orthographic for consistent sizing
    const frustumSize = 4
    const aspect = 1
    this.camera = new THREE.OrthographicCamera(
      (frustumSize * aspect) / -2,
      (frustumSize * aspect) / 2,
      frustumSize / 2,
      frustumSize / -2,
      0.1,
      100
    )
    this.camera.position.z = 5

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

    // Create trefoil knot geometry with high resolution for smooth curves
    const geometry = new THREE.TorusKnotGeometry(1, tubeRadius, 256, 32, 2, 3)

    // Create outline geometry (slightly larger)
    const outlineGeometry = new THREE.TorusKnotGeometry(
      1,
      tubeRadius + outlineWidth,
      256,
      32,
      2,
      3
    )

    // Outline material - renders back faces only
    const outlineMaterial = new THREE.MeshBasicMaterial({
      color: new THREE.Color(outlineColor),
      side: THREE.BackSide,
    })

    // Main material - flat color
    const mainMaterial = new THREE.MeshBasicMaterial({
      color: new THREE.Color(color),
    })

    // Create group with meshes
    this.group = new THREE.Group()
    this.group.add(new THREE.Mesh(outlineGeometry, outlineMaterial))
    this.group.add(new THREE.Mesh(geometry, mainMaterial))
    this.scene.add(this.group)

    // Set initial rotation
    this.group.rotation.x = this.baseRotationX
    this.group.rotation.y = this.baseRotationY

    // Initial render
    this.renderer.render(this.scene, this.camera)
  }

  get canvas(): HTMLCanvasElement {
    return this.renderer.domElement
  }

  startAnimation(): void {
    if (this.animationId !== null) return

    this.startTime = performance.now()
    const animate = () => {
      this.animationId = requestAnimationFrame(animate)

      const elapsed = (performance.now() - this.startTime) / 1000

      // Continuous rotation
      this.group.rotation.x = this.baseRotationX
      this.group.rotation.y = this.baseRotationY + elapsed * this.rotationSpeed

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
