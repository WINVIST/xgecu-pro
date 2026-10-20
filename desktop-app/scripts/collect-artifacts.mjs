import { readdirSync, copyFileSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { createHash } from 'node:crypto';

const output = resolve('artifacts');
mkdirSync(output, {recursive:true});
const target = process.env.CARGO_TARGET_DIR || resolve('src-tauri/target');
const bundle = join(target, 'release/bundle');
function find(root, extension) {
  for (const entry of readdirSync(root,{withFileTypes:true})) {
    const path = join(root,entry.name);
    if (entry.isDirectory()) { const nested=find(path,extension); if(nested)return nested; }
    else if(entry.name.endsWith(extension)) return path;
  }
}
const targets=process.platform==='win32'
  ? [['.exe','XGecuPro-Windows-x64-setup.exe']]
  : [['.deb','XGecuPro-Linux-x64.deb'],['.AppImage','XGecuPro-Linux-x64.AppImage']];
for(const [extension,name] of targets) {
  const source=find(bundle,extension);
  if(!source)throw new Error(`Missing ${extension} bundle`);
  const dest=join(output,name);copyFileSync(source,dest);
  const hash=createHash('sha256').update(readFileSync(dest)).digest('hex');
  writeFileSync(`${dest}.sha256`,`${hash}  ${name}\n`);
  console.log(`${name}: ${hash}`);
}
copyFileSync('src-tauri/resources/USB-SETUP.txt',join(output,`XGecuPro-${process.platform==='win32'?'Windows':'Linux'}-USB-Setup.txt`));
