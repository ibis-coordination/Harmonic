/**
 * Generates an SVG trefoil knot logo for Trio.
 * A trefoil knot represents three interlocking loops - perfect for a voting ensemble of three models.
 *
 * The knot is drawn as a thick tube with 3 segments, layered to show over/under crossings.
 */

interface TrefoilOptions {
  size?: number
  tubeWidth?: number
  color?: string
  backgroundColor?: string
}

/**
 * Generate a point on the trefoil knot curve.
 * x(t) = sin(t) + 2*sin(2t)
 * y(t) = cos(t) - 2*cos(2t)
 */
function trefoilPoint(t: number): { x: number; y: number } {
  return {
    x: Math.sin(t) + 2 * Math.sin(2 * t),
    y: Math.cos(t) - 2 * Math.cos(2 * t),
  }
}

/**
 * Get the tangent vector at point t (normalized).
 */
function trefoilTangent(t: number): { tx: number; ty: number } {
  // Derivative of parametric equations
  const tx = Math.cos(t) + 4 * Math.cos(2 * t)
  const ty = -Math.sin(t) + 4 * Math.sin(2 * t)
  const len = Math.sqrt(tx * tx + ty * ty)
  return { tx: tx / len, ty: ty / len }
}

/**
 * Get perpendicular (normal) vector for creating tube offset.
 */
function trefoilNormal(t: number): { nx: number; ny: number } {
  const { tx, ty } = trefoilTangent(t)
  // Rotate 90 degrees
  return { nx: -ty, ny: tx }
}

/**
 * Generate inner and outer edge points for a tube segment.
 */
function generateTubeSegment(
  tStart: number,
  tEnd: number,
  tubeRadius: number,
  numPoints: number
): { outer: Array<[number, number]>; inner: Array<[number, number]> } {
  const outer: Array<[number, number]> = []
  const inner: Array<[number, number]> = []

  for (let i = 0; i <= numPoints; i++) {
    const t = tStart + (i / numPoints) * (tEnd - tStart)
    const p = trefoilPoint(t)
    const { nx, ny } = trefoilNormal(t)

    outer.push([p.x + nx * tubeRadius, p.y + ny * tubeRadius])
    inner.push([p.x - nx * tubeRadius, p.y - ny * tubeRadius])
  }

  return { outer, inner }
}

/**
 * Create a closed path string for a tube segment (filled band).
 */
function tubeSegmentToPath(
  outer: Array<[number, number]>,
  inner: Array<[number, number]>,
  scale: number,
  offsetX: number,
  offsetY: number
): string {
  const transform = (pt: [number, number]): string => {
    const x = pt[0] * scale + offsetX
    const y = pt[1] * scale + offsetY
    return `${x.toFixed(2)} ${y.toFixed(2)}`
  }

  // Go forward along outer edge
  let path = `M ${transform(outer[0])}`
  for (let i = 1; i < outer.length; i++) {
    path += ` L ${transform(outer[i])}`
  }

  // Come back along inner edge (reversed)
  for (let i = inner.length - 1; i >= 0; i--) {
    path += ` L ${transform(inner[i])}`
  }

  path += " Z"
  return path
}

/**
 * The trefoil is divided into 3 segments. Each segment spans ~2π/3 radians.
 * Drawing order determines over/under: segment drawn last appears on top.
 *
 * Crossing points are approximately at t = π/3, π, 5π/3
 * We offset slightly to make the visual crossings cleaner.
 */
function getSegmentRanges(): Array<{ tStart: number; tEnd: number; drawOrder: number }> {
  const PI = Math.PI
  // Three segments, each covering roughly 1/3 of the curve
  // Adjusted to have crossings at segment boundaries
  const offset = PI / 6 // Offset to center crossings better

  return [
    { tStart: offset, tEnd: offset + (2 * PI) / 3, drawOrder: 1 },
    { tStart: offset + (2 * PI) / 3, tEnd: offset + (4 * PI) / 3, drawOrder: 2 },
    { tStart: offset + (4 * PI) / 3, tEnd: offset + 2 * PI, drawOrder: 0 },
  ]
}

/**
 * Generate an SVG trefoil knot logo with visible over/under crossings.
 */
export function generateTrefoilSvg(options: TrefoilOptions = {}): string {
  const {
    size = 48,
    tubeWidth = 6,
    color = "currentColor",
    backgroundColor = "var(--color-canvas-default, white)",
  } = options

  // Scale to fit within the viewBox with padding
  // The trefoil extends roughly from -3 to 3 in both dimensions
  const tubeRadius = tubeWidth / 2 / 7 // Normalize to trefoil coordinate space
  const padding = tubeWidth + 4
  const viewBoxSize = size
  const scale = (viewBoxSize - padding * 2) / 6
  const offset = viewBoxSize / 2

  const segments = getSegmentRanges()
  const pointsPerSegment = 60

  // Generate all segment paths
  const segmentPaths: Array<{ path: string; drawOrder: number }> = []

  for (const seg of segments) {
    const { outer, inner } = generateTubeSegment(seg.tStart, seg.tEnd, tubeRadius, pointsPerSegment)
    const path = tubeSegmentToPath(outer, inner, scale, offset, offset)
    segmentPaths.push({ path, drawOrder: seg.drawOrder })
  }

  // Sort by draw order (lower = drawn first = appears behind)
  segmentPaths.sort((a, b) => a.drawOrder - b.drawOrder)

  // Stroke width for the background border effect
  const strokeWidth = 2

  return `<svg
  xmlns="http://www.w3.org/2000/svg"
  width="${size}"
  height="${size}"
  viewBox="0 0 ${viewBoxSize} ${viewBoxSize}"
  class="trio-logo"
  aria-label="Trio logo"
  role="img"
>
  ${segmentPaths.map((s) => `<path d="${s.path}" fill="${color}" stroke="${backgroundColor}" stroke-width="${strokeWidth}" />`).join("\n  ")}
</svg>`
}

/**
 * Insert the trefoil logo into a DOM element.
 */
export function insertTrefoilLogo(container: HTMLElement, options: TrefoilOptions = {}): void {
  container.innerHTML = generateTrefoilSvg(options)
}
