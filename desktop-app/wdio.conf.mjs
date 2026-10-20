import {spawn} from 'node:child_process';
import {appendFileSync,mkdirSync,writeFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {connect} from 'node:net';

let driver;
const port=Number(process.env.XGECU_DRIVER_PORT||4444);
const variant=process.env.XGECU_E2E_VARIANT||'installed';
const commandLog=join('test-results','webdriver',`${variant}-commands-${process.pid}.jsonl`);
const inFlight=[];
let commandSequence=0;
let currentTest='session setup';
function trace(event){
  mkdirSync(resolve('test-results','webdriver'),{recursive:true});
  appendFileSync(commandLog,JSON.stringify({time:new Date().toISOString(),pid:process.pid,test:currentTest,...event})+'\n');
}
function summarize(value){
  if(typeof value==='string')return value.length<=160?value:`<string length=${value.length}>`;
  if(Array.isArray(value))return {type:'array',length:value.length};
  if(value&&typeof value==='object')return {type:'object',keys:Object.keys(value).slice(0,12)};
  return value;
}
async function waitForDriver(){
  const until=Date.now()+20_000;
  while(Date.now()<until){
    const ready=await new Promise(resolve=>{const socket=connect(port,'127.0.0.1');socket.once('connect',()=>{socket.destroy();resolve(true)});socket.once('error',()=>resolve(false));socket.setTimeout(1000,()=>{socket.destroy();resolve(false)})});
    if(ready)return;
    await new Promise(resolve=>setTimeout(resolve,200));
  }
  throw new Error('The native Tauri WebDriver did not start');
}

export const config={
  hostname:'127.0.0.1',port,
  specs:['./e2e/native.spec.mjs'],
  maxInstances:1,
  capabilities:[{'wdio:enforceWebDriverClassic':true,'tauri:options':{application:process.env.XGECU_E2E_APP||resolve('src-tauri/target/release',process.platform==='win32'?'XGecuPro.exe':'XGecuPro')}}],
  logLevel:'info',
  outputDir:'./test-results/webdriver',
  framework:'mocha',reporters:['spec'],
  waitforTimeout:20_000,connectionRetryTimeout:120_000,connectionRetryCount:0,
  bail:1,
  mochaOpts:{timeout:120_000,bail:true},
  beforeSession:()=>trace({phase:'session:start',application:process.env.XGECU_E2E_APP,platform:process.platform}),
  beforeTest:test=>{
    currentTest=`${test.parent||''}.${test.title}`;
    trace({phase:'test:start'});
    console.log(`[native-e2e] ${new Date().toISOString()} test:start ${currentTest}`);
  },
  beforeCommand:(commandName,args)=>{
    const entry={id:++commandSequence,command:commandName,started:Date.now()};
    inFlight.push(entry);
    trace({phase:'command:start',id:entry.id,command:commandName,args:args.map(summarize)});
  },
  afterCommand:(commandName,_args,result,error)=>{
    const index=inFlight.findLastIndex(entry=>entry.command===commandName);
    const entry=index<0?undefined:inFlight.splice(index,1)[0];
    trace({phase:'command:end',id:entry?.id,command:commandName,milliseconds:entry?Date.now()-entry.started:undefined,result:summarize(result),error:error?{name:error.name,message:error.message.slice(0,1200)}:undefined});
  },
  onPrepare:async()=>{
    mkdirSync(join('screenshots',process.env.XGECU_E2E_VARIANT||'installed'),{recursive:true});mkdirSync('test-results',{recursive:true});
    writeFileSync('test-results/editor-source.bin',Buffer.from(Array.from({length:256},(_,i)=>i)));
    writeFileSync('test-results/editor-other.bin',Buffer.from(Array.from({length:256},(_,i)=>i)));
    writeFileSync('test-results/native-environment.json',JSON.stringify({platform:process.platform,application:process.env.XGECU_E2E_APP,hardwareTested:false,dialogSelection:'WebDriver injects only the native dialog result; all file and helper operations use the real installed backend'},null,2));
    if(process.env.XGECU_DRIVER_EXTERNAL!=='1'){
      driver=spawn(process.platform==='win32'?'tauri-driver.exe':'tauri-driver',['--port',String(port)],{stdio:'inherit',windowsHide:true});
      driver.on('error',error=>console.error(`Tauri driver: ${error.message}`));
    }
    await waitForDriver();
  },
  afterTest:async function(test,_context,{passed,error,duration}){
    trace({phase:'test:end',passed,duration,error:error?{name:error.name,message:error.message.slice(0,1200)}:undefined,inFlight:inFlight.map(entry=>({id:entry.id,command:entry.command,milliseconds:Date.now()-entry.started}))});
    console.log(`[native-e2e] ${new Date().toISOString()} test:end passed=${passed} ${test.title}`);
    if(!passed){
      const path=join('screenshots',`FAILED-${test.title.replace(/[^a-z0-9]+/gi,'-')}.png`);
      trace({phase:'failure-screenshot:start',path});
      try{await browser.saveScreenshot(path);trace({phase:'failure-screenshot:end',path})}
      catch(screenshotError){trace({phase:'failure-screenshot:error',message:String(screenshotError).slice(0,1200)})}
    }
  },
  onComplete:()=>{driver?.kill()}
};
