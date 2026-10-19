import {spawnSync} from 'node:child_process';
import {readFileSync,mkdirSync} from 'node:fs';
import assert from 'node:assert/strict';

mkdirSync('test-results',{recursive:true});
const build=spawnSync('cargo',['test','--manifest-path','src-tauri/Cargo.toml','--lib','--release','--locked','--no-run','--message-format=json'],{encoding:'utf8',maxBuffer:32*1024*1024});
process.stderr.write(build.stderr||'');
if(build.status!==0)throw new Error(`Large-image test build failed (${build.status})`);
const executable=build.stdout.split('\n').filter(Boolean).map(line=>{try{return JSON.parse(line)}catch{return {}}}).find(message=>message.reason==='compiler-artifact'&&message.target?.name==='xgecu_pro_desktop'&&message.executable)?.executable;
if(!executable)throw new Error('Large-image test executable is missing');
const args=['hex::tests::large_fixture_and_exact_two_gib_boundary_have_bounded_pages_and_undo','--exact','--ignored','--nocapture'];
const run=process.platform==='linux'?spawnSync('/usr/bin/time',['-v','-o','test-results/large-buffer-memory.txt',executable,...args],{encoding:'utf8'}):spawnSync(executable,args,{encoding:'utf8'});
process.stdout.write(run.stdout||'');process.stderr.write(run.stderr||'');
if(run.status!==0)throw new Error(`Large-image test failed (${run.status})`);
assert.match(run.stdout||'',/test result: ok\. 1 passed;/,'The explicit large-image test must actually execute');
if(process.platform==='linux'){
  const memory=readFileSync('test-results/large-buffer-memory.txt','utf8');
  const peak=Number(memory.match(/Maximum resident set size \(kbytes\):\s*(\d+)/)?.[1]);
  assert.ok(peak>0&&peak<128*1024,`File-backed engine exceeded the 128 MiB gate: ${peak} KiB`);
  console.log(`Large-image engine peak RSS: ${peak} KiB`);
}
