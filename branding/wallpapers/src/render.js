// Renders the chosen wallpapers to the Plasma wallpaper package layout.
// node src/render.js OUTDIR   (Playwright + Chromium)
const {chromium} = require('playwright');
const fs = require('fs'), path = require('path');
const SIZES = [[3840, 2160], [2560, 1600], [1920, 1080]];
const VARIANTS = {images: 'graveyard-4-dunes-jour.svg', images_dark: 'graveyard-3-dunes-nuit.svg'};
(async () => {
  const out = process.argv[2];
  const b = await chromium.launch();
  for (const [dir, svgName] of Object.entries(VARIANTS)) {
    const svg = fs.readFileSync(path.join(__dirname, '..', 'svg', svgName), 'utf8')
      .replace('<svg ', '<svg style="display:block;width:100vw;height:100vh" ');
    fs.mkdirSync(path.join(out, 'contents', dir), {recursive: true});
    for (const [w, h] of SIZES) {
      const p = await b.newPage({viewport: {width: w / 2, height: h / 2}, deviceScaleFactor: 2});
      await p.setContent(`<html><body style="margin:0">${svg}</body></html>`);
      await p.waitForTimeout(300);
      await p.screenshot({path: path.join(out, 'contents', dir, `${w}x${h}.jpg`), type: 'jpeg', quality: 92});
      await p.close();
    }
  }
  await b.close();
})();
