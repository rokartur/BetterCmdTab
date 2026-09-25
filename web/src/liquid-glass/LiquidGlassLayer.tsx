/**
 * LiquidGlassLayer, drop-in glass background for any rounded container.
 * Ported from BetterAudio's web; the at-rest look matches upstream.
 *
 * Place inside a `position: relative` parent. The layer covers the parent
 * (1px proud on every side) and applies an SVG-driven `backdrop-filter`, so
 * whatever scrolls behind gets refracted at the bezel (Chromium only; other
 * browsers get a plain `blur()`).
 *
 * Deviations from upstream, so the glass stays intact during a size morph:
 *   - The displacement map is a 9-slice (`generateEdgeTiles`) baked per corner
 *     radius. The ResizeObserver lays the 8 <feImage> tiles out on every frame;
 *     upstream stretched one full-size PNG until a new one decoded, which
 *     smeared the corners mid-morph.
 *   - The specular rim is a CSS ring instead of a per-size SVG image.
 *   - Params are fixed to DEFAULT_LIQUID_GLASS_PARAMS (no tuning panel).
 */
import { useEffect, useId, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";

import {
  DEFAULT_LIQUID_GLASS_PARAMS,
  EDGE_TILES,
  generateEdgeTiles,
  type EdgeTile,
} from "./liquidGlass";

interface Props {
  /** Border-radius in px, used when the parent has no inline border-radius.
   *  `Infinity` means fully rounded. Defaults to half the parent height. */
  radius?: number;
  className?: string;
}

// Rebake the tiles only once the parent has stopped resizing for this long;
// mid-morph the current tiles are scaled to the live radius instead.
const RESIZE_DEBOUNCE_MS = 80;
const params = DEFAULT_LIQUID_GLASS_PARAMS;

// Browser support never changes at runtime, so there is nothing to subscribe to.
const subscribeNever = () => () => {};

let backdropSupportsSvg: boolean | null = null;
function detectBackdropSvgSupport(): boolean {
  if (backdropSupportsSvg !== null) return backdropSupportsSvg;
  const isChromium = /\b(?:Chrome|Chromium|Edg|OPR)\//.test(navigator.userAgent);
  if (!isChromium) {
    backdropSupportsSvg = false;
    return backdropSupportsSvg;
  }
  const probe = document.createElement("div");
  probe.style.backdropFilter = "url(#__lg_probe__)";
  // Chromium keeps the url(); Firefox/Safari clear the property entirely.
  backdropSupportsSvg = probe.style.backdropFilter.includes("url");
  return backdropSupportsSvg;
}

function currentRenderScale() {
  const zoom = window.visualViewport?.scale ?? 1;
  return Math.max(1, Math.min(4, window.devicePixelRatio * zoom));
}

export function LiquidGlassLayer({ radius, className }: Props) {
  const wrapperRef = useRef<HTMLDivElement>(null);
  const tileRefs = useRef<Partial<Record<EdgeTile, SVGFEImageElement>>>({});
  const displacementMapRef = useRef<SVGFEDisplacementMapElement>(null);
  const filterId = `liquid-glass-${useId().replace(/[:]/g, "")}`;

  const radiusRef = useRef(radius);
  useLayoutEffect(() => {
    radiusRef.current = radius;
  });
  const sizeRef = useRef({ width: 0, height: 0 });
  const supportsSvg = useSyncExternalStore(subscribeNever, detectBackdropSvgSupport, () => false);
  const [tileRadius, setTileRadius] = useState(0);
  const [renderScale, setRenderScale] = useState(1);

  // Lays the tiles out for the parent's current size and radius. Only
  // attribute writes, so it can run on every animation frame.
  const layoutTiles = () => {
    const parent = wrapperRef.current?.parentElement;
    if (!parent) return;
    // Fractional border box: clientWidth/Height round, which leaves the far
    // edge tiles up to 0.5px off while the morph animates sub-pixel sizes.
    const w = sizeRef.current.width + 2;
    const h = sizeRef.current.height + 2;
    const c = Math.min(liveRadius(parent, radiusRef.current), w / 2, h / 2);
    const rects: Record<EdgeTile, [number, number, number, number]> = {
      top: [c - 1, 0, w - 2 * c + 2, c],
      right: [w - c, c - 1, c, h - 2 * c + 2],
      bottom: [c - 1, h - c, w - 2 * c + 2, c],
      left: [0, c - 1, c, h - 2 * c + 2],
      topLeft: [0, 0, c, c],
      topRight: [w - c, 0, c, c],
      bottomRight: [w - c, h - c, c, c],
      bottomLeft: [0, h - c, c, c],
    };
    for (const tile of EDGE_TILES) {
      const image = tileRefs.current[tile];
      if (!image) continue;
      const [x, y, width, height] = rects[tile];
      image.setAttribute("x", String(x));
      image.setAttribute("y", String(y));
      image.setAttribute("width", String(width));
      image.setAttribute("height", String(height));
    }
  };

  useLayoutEffect(() => {
    const parent = wrapperRef.current?.parentElement;
    if (!parent) return;
    let pending: number | undefined;
    const ro = new ResizeObserver(([entry]) => {
      const [box] = entry.borderBoxSize;
      sizeRef.current = { width: box.inlineSize, height: box.blockSize };
      layoutTiles();
      clearTimeout(pending);
      pending = window.setTimeout(() => {
        const r = liveRadius(parent, radiusRef.current);
        const maxRadius = Math.min(parent.clientWidth, parent.clientHeight) / 2 + 1;
        setTileRadius(Math.round(Math.min(r, maxRadius)));
      }, RESIZE_DEBOUNCE_MS);
    });
    ro.observe(parent);
    return () => {
      ro.disconnect();
      clearTimeout(pending);
    };
  }, []);

  // ResizeObserver does not fire on DPR or zoom changes, so track those.
  useEffect(() => {
    const update = () => setRenderScale(currentRenderScale());
    let mql: MediaQueryList | undefined;
    const armDprListener = () => {
      mql?.removeEventListener("change", onDprChange);
      mql = window.matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`);
      mql.addEventListener("change", onDprChange);
    };
    const onDprChange = () => {
      update();
      armDprListener();
    };
    update();
    armDprListener();
    window.visualViewport?.addEventListener("resize", update, { passive: true });
    return () => {
      window.visualViewport?.removeEventListener("resize", update);
      mql?.removeEventListener("change", onDprChange);
    };
  }, []);

  useEffect(() => {
    if (!supportsSvg || tileRadius < 1) return;
    let cancelled = false;
    const { urls, maximumDisplacement } = generateEdgeTiles(tileRadius, params, renderScale);
    // Decode first so the swap lands in one frame instead of blanking tiles.
    void Promise.all(
      EDGE_TILES.map((tile) => {
        const image = new Image();
        image.src = urls[tile];
        return image.decode();
      }),
    ).then(() => {
      if (cancelled) return;
      for (const tile of EDGE_TILES) tileRefs.current[tile]?.setAttribute("href", urls[tile]);
      displacementMapRef.current?.setAttribute(
        "scale",
        String(maximumDisplacement * params.refractionScale),
      );
      layoutTiles();
    });
    return () => {
      cancelled = true;
    };
  }, [supportsSvg, tileRadius, renderScale]);

  const backdropFilter = supportsSvg ? `url(#${filterId})` : "blur(14px)";
  const decorativeGradient =
    "linear-gradient(135deg, rgba(255,255,255,0.06), rgba(255,255,255,0.02) 60%, rgba(0,0,0,0.04))";

  // `calc(100% + 2px)` tracks the parent's animated size with no React
  // re-render; the 1px outset keeps Chrome's integer-snapped corner clip from
  // cutting into sub-pixel parent widths.
  return (
    <div
      ref={wrapperRef}
      aria-hidden
      className={"pointer-events-none absolute overflow-hidden " + (className ?? "")}
      style={{
        left: -1,
        top: -1,
        width: "calc(100% + 2px)",
        height: "calc(100% + 2px)",
        background: `${decorativeGradient}, rgba(0, 0, 0, ${params.tint})`,
        boxShadow:
          "inset 0 1px 0 rgba(255,255,255,0.18), inset 0 -1px 0 rgba(0,0,0,0.18), 0 18px 50px -22px rgba(0,0,0,0.55)",
        backdropFilter,
        WebkitBackdropFilter: backdropFilter,
      }}
    >
      {supportsSvg ? (
        <>
          {/* Upstream screen-blended this ring under the 0.6 tint, hence alpha
              x0.4; stops are its bounding-box gradient's 0/55/100% in CSS terms. */}
          <div
            className="absolute inset-[0.25px] [border-radius:inherit] border-[1.5px] border-transparent"
            style={{
              background:
                "linear-gradient(to bottom left, rgba(255,255,255,0.4) 14.6%, rgba(255,255,255,0.08) 53.5%, rgba(255,255,255,0) 85.4%) border-box",
              mask: "linear-gradient(#000 0 0) padding-box exclude, linear-gradient(#000 0 0)",
            }}
          />
          <svg className="absolute size-0" aria-hidden>
            <filter
              id={filterId}
              x="-50%"
              y="-50%"
              width="200%"
              height="200%"
              colorInterpolationFilters="sRGB"
            >
              <feGaussianBlur in="SourceGraphic" stdDeviation={params.blur} result="blurred" />
              {/* Neutral (128,128) everywhere the tiles do not cover; the default
                  transparent black would pull every pixel left and up. */}
              <feFlood floodColor="rgb(128,128,0)" result="neutral" />
              {EDGE_TILES.map((tile) => (
                <feImage
                  key={tile}
                  ref={(image) => {
                    tileRefs.current[tile] = image ?? undefined;
                  }}
                  preserveAspectRatio="none"
                  result={tile}
                />
              ))}
              <feMerge result="displacement_map">
                <feMergeNode in="neutral" />
                {EDGE_TILES.map((tile) => (
                  <feMergeNode key={tile} in={tile} />
                ))}
              </feMerge>
              <feDisplacementMap
                ref={displacementMapRef}
                in="blurred"
                in2="displacement_map"
                scale={0}
                xChannelSelector="R"
                yChannelSelector="G"
              />
            </filter>
          </svg>
        </>
      ) : null}
    </div>
  );
}

function liveRadius(parent: HTMLElement, radius: number | undefined) {
  const inline = parseFloat(parent.style.borderRadius);
  if (Number.isFinite(inline)) return inline;
  return radius ?? parent.clientHeight / 2;
}
