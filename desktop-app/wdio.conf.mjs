import {spawn} from 'node:child_process';
import {mkdirSync,writeFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {connect} from 'node:net';

let driver;
const port=Number(process.env.XGECU_DRIVER_PORT||4444);
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
  logLevel:'warn',
  outputDir:'./test-results/webdriver',
  framework:'mocha',reporters:['spec'],
  waitforTimeout:20_000,connectionRetryTimeout:120_000,connectionRetryCount:0,
  mochaOpts:{timeout:120_000},
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
  afterTest:async function(test,_context,{passed}){
    if(!passed){try{await browser.saveScreenshot(join('screenshots',`FAILED-${test.title.replace(/[^a-z0-9]+/gi,'-')}.png`))}catch{}}
  },
  onComplete:()=>{driver?.kill()}
};
