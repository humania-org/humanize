export function brandHeaderHtml(appVersion: string): string {
  const version = escapeHtmlLiteral(appVersion.trim() || "unknown");

  return `<h1 class="brand-lockup">
      <span class="brand-mark polyarch-mark" aria-hidden="true">
        <svg viewBox="0 0 200 200" role="img" aria-label="PolyArch mark">
          <g stroke="currentColor" stroke-width="14" stroke-linecap="square" fill="none">
            <line x1="30" y1="37" x2="30" y2="163"></line>
            <line x1="37" y1="30" x2="100" y2="30"></line>
            <line x1="100" y1="30" x2="100" y2="100"></line>
            <line x1="30" y1="100" x2="100" y2="100"></line>
          </g>
          <g stroke="#3284BF" stroke-width="14" stroke-linecap="square" fill="none">
            <line x1="170" y1="37" x2="170" y2="163"></line>
            <line x1="37" y1="163" x2="163" y2="37"></line>
          </g>
          <rect x="84" y="84" width="32" height="32" fill="#3284BF" stroke="currentColor" stroke-width="8"></rect>
        </svg>
      </span>
      <span class="brand-copy">
        <span class="brand-mainline">
          <a class="brand-text" href="https://github.com/PolyArch/humanize" target="_blank" rel="noreferrer">Humanize2</a>
          <span class="brand-version">v${version}</span>
        </span>
        <span class="brand-byline">by <a href="https://github.com/SihaoLiu" target="_blank" rel="noreferrer">Sihao Liu</a> and <a href="https://github.com/PolyArch/humanize/graphs/contributors" target="_blank" rel="noreferrer">community</a></span>
      </span>
    </h1>`;
}

export function humanizeFaviconHref(): string {
  const svg = [
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">',
    '<rect x="2" y="2" width="28" height="28" fill="#ffd33d" stroke="#111" stroke-width="3"/>',
    '<rect x="7" y="7" width="18" height="18" fill="#2d2d2d" stroke="#f4ecd8" stroke-width="2"/>',
    '<path d="M10 23 L23 10" stroke="#3284BF" stroke-width="4" stroke-linecap="square"/>',
    '<path d="M10 10 H16 V16 H10 Z" fill="none" stroke="#111" stroke-width="2"/>',
    '<rect x="14" y="14" width="4" height="4" fill="#3284BF" stroke="#111" stroke-width="1"/>',
    "</svg>"
  ].join("");

  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

function escapeHtmlLiteral(value: string): string {
  return value.replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;"
  })[char] ?? char);
}
