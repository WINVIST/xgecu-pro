#!/usr/bin/env node
// Developer-only: npm install --no-save sharp, then run this script.
// The checked-in PNGs let DMG builds run without Node or sharp.
const fs = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');

async function main() {
  const design = path.resolve(__dirname, '../design/dmg');
  const { width, height } = JSON.parse(fs.readFileSync(path.join(design, 'layout.json'), 'utf8'));
  const source = fs.readFileSync(path.join(design, 'background.svg'));
  for (const scale of [1, 2]) {
    await sharp(source, { density: 72 * scale })
      .resize(width * scale, height * scale)
      .withMetadata({ density: 72 * scale })
      .png()
      .toFile(path.join(design, `background${scale === 2 ? '@2x' : ''}.png`));
  }
  console.log(`Exported ${width}x${height} and ${width * 2}x${height * 2} DMG backgrounds.`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
