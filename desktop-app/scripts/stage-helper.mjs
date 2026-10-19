import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, chmodSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const app = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const rustc = process.env.RUSTC || 'rustc';
const target = process.env.TAURI_ENV_TARGET_TRIPLE || process.env.CARGO_BUILD_TARGET ||
  execFileSync(rustc, ['-vV'], {encoding: 'utf8'}).match(/^host: (.+)$/m)?.[1];
if (!target) throw new Error('Cannot identify the helper target triple');
const extension = target.includes('windows') ? '.exe' : '';
const profile = process.env.HELPER_PROFILE || 'release';
const supplied = process.argv[2];
const targetRoot = process.env.CARGO_TARGET_DIR || resolve(app, '../minipro-rs/target');
const source = supplied ? resolve(supplied) : join(targetRoot, ...(process.env.CARGO_BUILD_TARGET ? [target] : []), profile, `minipro${extension}`);
const output = join(app, 'src-tauri/binaries', `minipro-${target}${extension}`);
mkdirSync(dirname(output), {recursive: true});
copyFileSync(source, output);
if (!extension) chmodSync(output, 0o755);
console.log(`Staged ${target} helper`);
