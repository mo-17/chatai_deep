const path = require("node:path");
const { pathToFileURL } = require("node:url");

const VIEWPORT = { width: 2048, height: 1536 };
const BUNDLED_PLAYWRIGHT =
  "/Users/huangzhibin/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright";

function resolvePlaywright() {
  const candidates = [];
  if (process.env.STARCORE_PLAYWRIGHT_MODULE) {
    candidates.push({
      label: "STARCORE_PLAYWRIGHT_MODULE",
      request: process.env.STARCORE_PLAYWRIGHT_MODULE,
    });
  }
  candidates.push(
    { label: "local playwright", request: "playwright" },
    { label: "bundled fallback", request: BUNDLED_PLAYWRIGHT },
  );

  const failures = [];
  for (const candidate of candidates) {
    try {
      const playwright = require(candidate.request);
      if (!playwright.chromium) {
        throw new Error("module does not export chromium");
      }
      return playwright;
    } catch (error) {
      failures.push(`${candidate.label}: ${error.message.split("\n", 1)[0]}`);
    }
  }
  throw new Error(`Unable to resolve Playwright:\n${failures.join("\n")}`);
}

async function assertPageReady(page) {
  await page.evaluate(async ({ width, height }) => {
    await document.fonts.ready;

    const images = Array.from(document.images);
    await Promise.all(
      images.map(async (image, index) => {
        try {
          await image.decode();
        } catch (error) {
          throw new Error(
            `image ${index + 1} failed to decode: ${image.getAttribute("src")}`,
          );
        }
        if (!image.complete || image.naturalWidth <= 0 || image.naturalHeight <= 0) {
          throw new Error(
            `image ${index + 1} is incomplete: ${image.getAttribute("src")}`,
          );
        }
      }),
    );

    const scrollWidth = Math.max(
      document.documentElement.scrollWidth,
      document.body.scrollWidth,
    );
    const scrollHeight = Math.max(
      document.documentElement.scrollHeight,
      document.body.scrollHeight,
    );
    if (scrollWidth > width || scrollHeight > height) {
      throw new Error(
        `document overflow: ${scrollWidth}x${scrollHeight}, viewport ${width}x${height}`,
      );
    }
  }, VIEWPORT);
}

(async () => {
  const { chromium } = resolvePlaywright();
  const root = __dirname;
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage({
      viewport: VIEWPORT,
      deviceScaleFactor: 1,
    });
    await page.goto(
      pathToFileURL(path.join(root, "contact-sheet.html")).href,
      { waitUntil: "load" },
    );
    await assertPageReady(page);
    await page.screenshot({
      path: path.join(root, "contact-sheet.png"),
      type: "png",
      animations: "disabled",
    });
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
