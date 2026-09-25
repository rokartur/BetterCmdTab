/**
 * Liquid Glass math, ported from BetterAudio's web (itself from
 * https://github.com/dotmrye/liquid-glass-demo). Deviation from upstream:
 * instead of one full-size displacement PNG plus a specular PNG per size,
 * `generateEdgeTiles()` bakes one 9-slice of the bezel per corner radius, so
 * the layer can follow a size morph by moving <feImage> tiles. The specular
 * rim is CSS in LiquidGlassLayer.
 */
export type SurfaceType = "convex_squircle" | "convex_circle" | "concave" | "lip";

export const SurfaceEquations: Record<SurfaceType, (x: number) => number> = {
  convex_circle: (x) => Math.sqrt(1 - Math.pow(1 - x, 2)),
  convex_squircle: (x) => Math.pow(1 - Math.pow(1 - x, 4), 1 / 4),
  concave: (x) => 1 - Math.sqrt(1 - Math.pow(x, 2)),
  lip: (x) => {
    const convex = Math.pow(1 - Math.pow(1 - Math.min(x * 2, 1), 4), 1 / 4);
    const concave = 1 - Math.sqrt(1 - Math.pow(1 - x, 2)) + 0.1;
    const smootherstep = 6 * Math.pow(x, 5) - 15 * Math.pow(x, 4) + 10 * Math.pow(x, 3);
    return convex * (1 - smootherstep) + concave * smootherstep;
  },
};

export interface LiquidGlassParams {
  surfaceType: SurfaceType;
  bezelWidth: number;
  glassThickness: number;
  refractiveIndex: number;
  refractionScale: number;
  specularOpacity: number;
  specularSaturation: number;
  /** Light-source angle for the specular highlight, in degrees.
   *  0° → highlight on the right edge, 90° → top edge. */
  specularAngle: number;
  blur: number;
  /** 0 = no tint, 1 = fully black overlay on top of the refracted backdrop. */
  tint: number;
}

export const DEFAULT_LIQUID_GLASS_PARAMS: LiquidGlassParams = {
  surfaceType: "convex_squircle",
  bezelWidth: 20,
  glassThickness: 200,
  refractiveIndex: 1.2,
  refractionScale: 1.5,
  specularOpacity: 1.0,
  specularSaturation: 1.0,
  specularAngle: 45,
  blur: 3.0,
  tint: 0.6,
};

// ─── 1D displacement along a single radius ───────────────────────────────────
// Snell's law applied to the bezel surface profile at `samples` points along
// the bezel width. Returns the lateral pixel displacement at each sample.
export function calculateDisplacementMap1D(
  glassThickness: number,
  bezelWidth: number,
  surfaceFn: (x: number) => number,
  refractiveIndex: number,
  samples = 128,
): number[] {
  const eta = 1 / refractiveIndex;

  function refract(normalX: number, normalY: number): [number, number] | null {
    const dot = normalY;
    const k = 1 - eta * eta * (1 - dot * dot);
    if (k < 0) return null;
    const kSqrt = Math.sqrt(k);
    return [-(eta * dot + kSqrt) * normalX, eta - (eta * dot + kSqrt) * normalY];
  }

  const result: number[] = [];
  for (let i = 0; i < samples; i++) {
    const x = i / samples;
    const y = surfaceFn(x);
    const dx = x < 1 ? 0.0001 : -0.0001;
    const y2 = surfaceFn(Math.max(0, Math.min(1, x + dx)));
    const derivative = (y2 - y) / dx;
    const magnitude = Math.sqrt(derivative * derivative + 1);
    const normalX = -derivative / magnitude;
    const normalY = -1 / magnitude;
    const refracted = refract(normalX, normalY);
    if (!refracted) {
      result.push(0);
    } else {
      const remainingHeightOnBezel = y * bezelWidth;
      const remainingHeight = remainingHeightOnBezel + glassThickness;
      result.push(refracted[0] * (remainingHeight / refracted[1]));
    }
  }
  return result;
}

// ─── 2D displacement map (RGB) ───────────────────────────────────────────────
// Sweeps the whole rounded-rectangle and writes per-pixel displacement vectors
// into the R (x) and G (y) channels of an ImageData.
export function calculateDisplacementMap2D(
  canvasWidth: number,
  canvasHeight: number,
  objectWidth: number,
  objectHeight: number,
  radius: number,
  bezelWidth: number,
  maximumDisplacement: number,
  precomputedMap: number[],
  /** Width of the soft outer falloff in canvas pixels. Default 1.5 — wider
   *  than a single pixel kills the visible "notch" at corner crowns when the
   *  CSS border-radius and the displacement-map radius drift sub-pixel. */
  outerFeather: number = 1.5,
): ImageData {
  const imageData = new ImageData(canvasWidth, canvasHeight);
  const data = imageData.data;

  for (let i = 0; i < data.length; i += 4) {
    data[i] = 128;
    data[i + 1] = 128;
    data[i + 2] = 0;
    data[i + 3] = 255;
  }

  const safeFeather = Math.max(0.5, outerFeather);
  const radiusSquared = radius * radius;
  const radiusOuterSquared = (radius + safeFeather) * (radius + safeFeather);
  const radiusMinusBezelSquared = Math.max(0, (radius - bezelWidth) * (radius - bezelWidth));
  const widthBetweenRadiuses = objectWidth - radius * 2;
  const heightBetweenRadiuses = objectHeight - radius * 2;
  const objectX = (canvasWidth - objectWidth) / 2;
  const objectY = (canvasHeight - objectHeight) / 2;

  for (let y1 = 0; y1 < objectHeight; y1++) {
    for (let x1 = 0; x1 < objectWidth; x1++) {
      const idx = ((objectY + y1) * canvasWidth + objectX + x1) * 4;
      const isOnLeftSide = x1 < radius;
      const isOnRightSide = x1 >= objectWidth - radius;
      const isOnTopSide = y1 < radius;
      const isOnBottomSide = y1 >= objectHeight - radius;

      const x = isOnLeftSide ? x1 - radius : isOnRightSide ? x1 - radius - widthBetweenRadiuses : 0;
      const y = isOnTopSide
        ? y1 - radius
        : isOnBottomSide
          ? y1 - radius - heightBetweenRadiuses
          : 0;

      const distanceToCenterSquared = x * x + y * y;
      const isInBezel =
        distanceToCenterSquared <= radiusOuterSquared &&
        distanceToCenterSquared >= radiusMinusBezelSquared;

      if (isInBezel) {
        const opacity =
          distanceToCenterSquared < radiusSquared
            ? 1
            : Math.max(0, 1 - (Math.sqrt(distanceToCenterSquared) - radius) / safeFeather);
        const distanceFromCenter = Math.sqrt(distanceToCenterSquared);
        const distanceFromSide = radius - distanceFromCenter;
        const cos = distanceFromCenter > 0 ? x / distanceFromCenter : 0;
        const sin = distanceFromCenter > 0 ? y / distanceFromCenter : 0;
        const bezelRatio = Math.max(0, Math.min(1, distanceFromSide / bezelWidth));
        const bezelIndex = Math.floor(bezelRatio * precomputedMap.length);
        const distance =
          precomputedMap[Math.max(0, Math.min(bezelIndex, precomputedMap.length - 1))] || 0;
        const dX = maximumDisplacement > 0 ? (-cos * distance) / maximumDisplacement : 0;
        const dY = maximumDisplacement > 0 ? (-sin * distance) / maximumDisplacement : 0;

        data[idx] = Math.max(0, Math.min(255, 128 + dX * 127 * opacity));
        data[idx + 1] = Math.max(0, Math.min(255, 128 + dY * 127 * opacity));
        data[idx + 2] = 0;
        data[idx + 3] = 255;
      }
    }
  }
  return imageData;
}

function computeDisplacementData(
  width: number,
  height: number,
  radius: number,
  params: LiquidGlassParams,
  renderScale: number,
  maxSS: number,
): { data: ImageData; maximumDisplacement: number } {
  const r1x = Math.max(1, Math.min(radius, Math.min(width, height) / 2));
  const bezel1x = Math.max(1, Math.min(params.bezelWidth, r1x));

  const safeRenderScale = Math.max(1, Math.min(4, renderScale || 1));
  const minRenderSide = Math.round(160 * safeRenderScale);
  const maxRenderSide = Math.round(360 * safeRenderScale);
  const shortSide = Math.max(1, Math.min(width, height));
  const ssRaw = minRenderSide / shortSide;
  const SS = Math.max(1, Math.min(maxSS, Math.ceil(ssRaw)));
  const SSCapped =
    shortSide * SS > maxRenderSide ? Math.max(1, Math.floor(maxRenderSide / shortSide)) : SS;

  const W = Math.max(2, Math.round(width * SSCapped));
  const H = Math.max(2, Math.round(height * SSCapped));
  const R = r1x * SSCapped;
  const B = bezel1x * SSCapped;
  const T = params.glassThickness * SSCapped;

  const surfaceFn = SurfaceEquations[params.surfaceType];
  const precomputed = calculateDisplacementMap1D(
    T,
    B,
    surfaceFn,
    params.refractiveIndex,
    Math.max(128, Math.round(B * 4)),
  );
  const maxAtSS = Math.max(...precomputed.map(Math.abs));
  const outerFeatherSS = Math.max(1, SSCapped) * 1.5;
  const data = calculateDisplacementMap2D(
    W,
    H,
    W,
    H,
    R,
    B,
    maxAtSS || 1,
    precomputed,
    outerFeatherSS,
  );
  return { data, maximumDisplacement: maxAtSS / SSCapped };
}

// Paint order: corners last, so they cover the edge strips' overlapping ends.
export const EDGE_TILES = [
  "top",
  "right",
  "bottom",
  "left",
  "topLeft",
  "topRight",
  "bottomRight",
  "bottomLeft",
] as const;
export type EdgeTile = (typeof EDGE_TILES)[number];

// 9-slice of the displacement map: the corner quadrants of a (2r+2)px rounded
// square, plus 1px strips across its straight edges, which stretch without
// distortion. Any size with this corner radius is covered by laying the tiles
// out again, so a morph never waits on a new image.
export function generateEdgeTiles(
  radius: number,
  params: LiquidGlassParams,
  renderScale: number,
): { urls: Record<EdgeTile, string>; maximumDisplacement: number } {
  const side = 2 * radius + 2;
  const { data, maximumDisplacement } = computeDisplacementData(
    side,
    side,
    radius,
    params,
    renderScale,
    8,
  );
  const source = canvas2d(data.width, data.height);
  source.ctx.putImageData(data, 0, 0);
  const scale = data.width / side;
  const r = radius * scale;
  const mid = (radius + 1) * scale;
  const far = (radius + 2) * scale;
  const crop = (x: number, y: number, w: number, h: number) => {
    const tile = canvas2d(w, h);
    tile.ctx.drawImage(source.canvas, x, y, w, h, 0, 0, w, h);
    return tile.canvas.toDataURL();
  };
  return {
    maximumDisplacement,
    urls: {
      topLeft: crop(0, 0, r, r),
      top: crop(mid, 0, 1, r),
      topRight: crop(far, 0, r, r),
      right: crop(far, mid, r, 1),
      bottomRight: crop(far, far, r, r),
      bottom: crop(mid, far, 1, r),
      bottomLeft: crop(0, far, r, r),
      left: crop(0, mid, r, 1),
    },
  };
}

function canvas2d(width: number, height: number) {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("2D canvas context unavailable");
  return { canvas, ctx };
}
