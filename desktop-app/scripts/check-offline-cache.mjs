import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {cpSync,existsSync,mkdirSync,mkdtempSync,readFileSync,readlinkSync,realpathSync,rmSync,writeFileSync} from 'node:fs';
import {homedir,tmpdir} from 'node:os';
import {dirname,join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const chip='MX66L1G45G@SOIC16';
const helperTimeout=45_000;

function describe(helper,cache){
  const env={...process.env,XDG_CACHE_HOME:cache,MINIPRO_TRUST_PINNED_DB_ONLY:'1'};
  for(const name of ['MINIPRO_DB_DIR','MINIPRO_DB_URL','MINIPRO_VENDOR_URL','MINIPRO_KEEP_BITSTREAM','HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy'])delete env[name];
  const started=Date.now();
  const result=spawnSync(helper,['--json','describe',chip],{env,encoding:'utf8',timeout:helperTimeout,maxBuffer:4*1024*1024,windowsHide:true});
  assert.ifError(result.error);
  assert.equal(result.signal,null,'The helper must return its own bounded network error, not be killed');
  let value;
  try{value=JSON.parse(result.stdout)}catch{throw new Error(`Helper returned non-JSON output: ${result.stdout}\n${result.stderr}`)}
  return {status:result.status,milliseconds:Date.now()-started,result:value};
}

function isolated(planFile){
  const plan=JSON.parse(readFileSync(planFile,'utf8'));
  let namespace;
  if(process.platform==='linux'){
    assert.equal(process.getuid(),plan.uid,'The isolated helper must run as the invoking user');
    namespace=readlinkSync('/proc/self/ns/net');
    assert.notEqual(namespace,plan.originalNamespace,'Network namespace isolation was not applied');
  }
  const evidence={platform:process.platform,isolation:process.platform==='linux'?'private Linux network namespace':'Windows outbound firewall rule scoped to helper executable',helper:plan.helper,uid:process.getuid?.(),originalNamespace:plan.originalNamespace,namespace,timeoutMilliseconds:helperTimeout};
  const cached=describe(plan.helper,plan.cached);
  evidence.cached=cached;
  writeFileSync(plan.evidence,JSON.stringify(evidence,null,2));
  assert.equal(cached.status,0,'Prepared database must remain available while networking is blocked');
  assert.equal(cached.result.ok,true);
  assert.equal(cached.result.code_bytes,134217728);
  assert.equal(cached.result.chip_id,'C2201B');
  assert.equal(existsSync(join(plan.empty,'minipro','xgpro-pinned-v1321')),false,'Negative control cache must start empty');
  const uncached=describe(plan.helper,plan.empty);
  evidence.uncached=uncached;
  writeFileSync(plan.evidence,JSON.stringify(evidence,null,2));
  assert.notEqual(uncached.status,0,'Uncached database unexpectedly downloaded despite network isolation');
  assert.equal(uncached.result.ok,false);
  assert.equal(uncached.result.code,'format');
  assert.match(uncached.result.msg,/could not reach the chip-database mirror/i,'Negative control must fail due to blocked network, rather than another setup error');
  assert.equal(existsSync(join(plan.empty,'minipro','xgpro-pinned-v1321','InfoICT76.dll')),false,'Negative control must not obtain the database');
  console.log(`Offline cache verified: cached describe passed; uncached request failed under ${evidence.isolation}.`);
}

function main(){
  const helper=realpathSync(process.argv[2]||'');
  assert.ok(['linux','win32'].includes(process.platform),'Offline isolation gate supports Linux and Windows');
  if(process.platform==='win32')assert.equal(process.env.GITHUB_ACTIONS,'true','Windows firewall isolation is permitted only inside GitHub Actions CI');
  const cache=process.env.XDG_CACHE_HOME
    ?join(resolve(process.env.XDG_CACHE_HOME),'minipro')
    :process.platform==='win32'
      ?join(process.env.LOCALAPPDATA||'', 'minipro','cache')
      :join(homedir(),'.cache','minipro');
  const source=join(cache,'xgpro-pinned-v1321');
  assert.ok(existsSync(join(source,'InfoICT76.dll')),'Run ci-helper-checks.mjs first to prepare the pinned database');
  mkdirSync('test-results',{recursive:true});
  const scratch=mkdtempSync(join(tmpdir(),'xgecu-offline-'));
  try{
    const cached=join(scratch,'cached'),empty=join(scratch,'empty');
    mkdirSync(join(cached,'minipro'),{recursive:true});mkdirSync(empty);
    cpSync(source,join(cached,'minipro','xgpro-pinned-v1321'),{recursive:true,errorOnExist:true,force:false});
    const script=fileURLToPath(import.meta.url);
    const plan={helper,cached,empty,evidence:resolve('test-results/offline-cache.json'),uid:process.getuid?.(),originalNamespace:process.platform==='linux'?readlinkSync('/proc/self/ns/net'):undefined};
    const planFile=join(scratch,'plan.json');writeFileSync(planFile,JSON.stringify(plan),{mode:0o600});
    let program,args;
    if(process.platform==='linux'){
      const isolation=['unshare','--net','--','setpriv','--reuid',String(process.getuid()),'--regid',String(process.getgid()),'--clear-groups','/usr/bin/env',`HOME=${homedir()}`,`PATH=${process.env.PATH||'/usr/bin:/bin'}`,process.execPath,script,'--isolated',planFile];
      program='sudo';
      args=['-n',...isolation];
    }else{
      program='pwsh';
      args=['-NoLogo','-NoProfile','-NonInteractive','-File',join(dirname(script),'check-offline-cache.ps1'),'-Helper',helper,'-NodeExecutable',process.execPath,'-WorkerScript',script,'-PlanFile',planFile];
    }
    const result=spawnSync(program,args,{encoding:'utf8',timeout:120_000,maxBuffer:4*1024*1024,windowsHide:true});
    process.stdout.write(result.stdout||'');process.stderr.write(result.stderr||'');
    assert.ifError(result.error);assert.equal(result.status,0,'The isolated offline cache gate failed');
  }finally{
    // Only remove the freshly allocated task directory, never a supplied path.
    assert.equal(dirname(realpathSync(scratch)),realpathSync(tmpdir()));
    rmSync(scratch,{recursive:true,force:true});
  }
}

if(process.argv[2]==='--isolated')isolated(process.argv[3]);else main();
