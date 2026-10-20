import {execFileSync,spawnSync} from 'node:child_process';
import {mkdtempSync,writeFileSync,readFileSync,mkdirSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import assert from 'node:assert/strict';

const helper=resolve(process.argv[2]);
const environment={...process.env,MINIPRO_REQUIRE_MODEL:'T76',MINIPRO_REQUIRE_CHIP_ID:'1',MINIPRO_TRUST_PINNED_DB_ONLY:'1'};
// Minimal Debian installations need not define a UTF-8 desktop locale.
// Exercise the real pinned first-use extraction under that inherited locale.
if(process.platform==='linux'){environment.LC_ALL='C';delete environment.LANG;}
for(const name of ['MINIPRO_DB_DIR','MINIPRO_DB_URL','MINIPRO_VENDOR_URL','MINIPRO_KEEP_BITSTREAM'])delete environment[name];
const run=(...args)=>JSON.parse(execFileSync(helper,['--json',...args],{env:environment,encoding:'utf8',maxBuffer:16*1024*1024}));
const diagnostic=run('usb-diagnose');
assert.equal(diagnostic.op,'usb-diagnose');
assert.equal(diagnostic.report.passed,false);
assert.equal(diagnostic.report.opening.interface_claimed,false);
assert.ok(diagnostic.report.error);
assert.deepEqual(diagnostic.report.probes,[]);
const missing=spawnSync(helper,['--json','info'],{env:environment,encoding:'utf8'});
assert.notEqual(missing.status,0);
assert.equal(JSON.parse(missing.stdout).code,'usb');
const all=run('search','','--limit','40000');
assert.equal(all.ok,true);assert.equal(all.more,false);
assert.ok(all.n>30000);assert.equal(all.hits.length,all.n);
assert.ok(all.hits.includes('MX25L51245G@SOIC16'));
assert.ok(all.hits.includes('MX66L1G45G@SOIC16'));
const first=run('describe','MX25L51245G@SOIC16');
assert.equal(first.code_bytes,67108864);assert.equal(first.chip_id,'C2201A');
const scratch=mkdtempSync(join(tmpdir(),'xgecu-Юникод '));
const source=join(scratch,'source file.bin'),dest=join(scratch,'roundtrip.hex'),back=join(scratch,'roundtrip.bin');
writeFileSync(source,Buffer.from([0,1,2,3,0xff]));
assert.equal(run('convert',source,dest).ok,true);
assert.equal(run('convert',dest,back).ok,true);
assert.deepEqual(readFileSync(back),readFileSync(source));
mkdirSync('test-results',{recursive:true});
writeFileSync('test-results/helper-checks.json',JSON.stringify({catalogEntries:all.n,diagnostic,unicodeRoundtrip:true,inheritedLocale:environment.LC_ALL||null},null,2));
console.log(`Helper checked: ${all.n} catalog entries; no-device diagnostic; Unicode format roundtrip`);
