(() => {
  // src/youtube-main.ts
  (() => {
    const MARK = "__stillVideo";
    const w = window;
    if (w[MARK]) return;
    w[MARK] = true;
    document.documentElement.setAttribute("data-still-video", "1");
    const AD_KEYS = /* @__PURE__ */ new Set([
      "adPlacements",
      "adSlots",
      "playerAds",
      "adBreakHeartbeatParams",
      "adBreakParams",
      "enforcementMessageViewModel",
      "adSafetyReason"
    ]);
    const AD_RENDERERS = /* @__PURE__ */ new Set([
      "adSlotRenderer",
      "inFeedAdLayoutRenderer",
      "promotedSparklesWebRenderer",
      "promotedSparklesTextSearchRenderer",
      "promotedVideoRenderer",
      "compactPromotedVideoRenderer",
      "searchPyvRenderer",
      "bannerPromoRenderer",
      "statementBannerRenderer",
      "displayAdRenderer",
      "actionCompanionAdRenderer",
      "adActionInterstitialRenderer",
      "playerLegacyDesktopWatchAdsRenderer",
      "merchandiseShelfRenderer"
    ]);
    let enabled = true;
    const MAX_DEPTH = 14;
    const isAdItem = (item, depth = 0) => {
      if (!item || typeof item !== "object" || depth > 3) return false;
      for (const key of Object.keys(item)) {
        if (AD_RENDERERS.has(key)) return true;
        const value = item[key];
        if (value && typeof value === "object" && !Array.isArray(value) && isAdItem(value, depth + 1)) return true;
      }
      return false;
    };
    const strip = (node, depth = 0) => {
      if (!enabled || !node || typeof node !== "object" || depth > MAX_DEPTH) return node;
      if (Array.isArray(node)) {
        for (let i = node.length - 1; i >= 0; i--) {
          if (isAdItem(node[i])) node.splice(i, 1);
          else strip(node[i], depth + 1);
        }
        return node;
      }
      for (const key of Object.keys(node)) {
        if (AD_KEYS.has(key)) {
          delete node[key];
        } else {
          const value = node[key];
          if (value && typeof value === "object") strip(value, depth + 1);
        }
      }
      return node;
    };
    const looksLikeYouTube = (value) => !!value && typeof value === "object" && ("responseContext" in value || "playerResponse" in value || "playabilityStatus" in value || "adPlacements" in value || "onResponseReceivedEndpoints" in value || "contents" in value);
    for (const name of ["ytInitialPlayerResponse", "ytInitialData", "playerResponse"]) {
      let value = w[name];
      try {
        Object.defineProperty(w, name, {
          configurable: true,
          get: () => value,
          set: (next) => {
            value = looksLikeYouTube(next) ? strip(next) : next;
          }
        });
        if (value) value = strip(value);
      } catch {
      }
    }
    const parse = JSON.parse;
    JSON.parse = function(...args) {
      const result = parse.apply(this, args);
      return looksLikeYouTube(result) ? strip(result) : result;
    };
    const json = Response.prototype.json;
    Response.prototype.json = async function() {
      const result = await json.call(this);
      return this.url.includes("/youtubei/") && looksLikeYouTube(result) ? strip(result) : result;
    };
    window.addEventListener("message", (event) => {
      if (event.source !== window || event.data?.source !== "still-video") return;
      if (Array.isArray(event.data.keys)) event.data.keys.forEach((k) => typeof k === "string" && AD_KEYS.add(k));
      if (Array.isArray(event.data.renderers)) event.data.renderers.forEach((k) => typeof k === "string" && AD_RENDERERS.add(k));
      if (event.data.paused === true) enabled = false;
    });
  })();
})();
