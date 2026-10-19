import {browser,$,expect} from '@wdio/globals';
import {readFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import assert from 'node:assert/strict';

const nativeFile=name=>process.env.XGECU_E2E_NATIVE_FIXTURE_PREFIX?`${process.env.XGECU_E2E_NATIVE_FIXTURE_PREFIX}/${name}`:resolve('test-results',name);
const status=()=>$('.operation-status');
async function chooseFile(file){
  // Only the native picker response is supplied by the test. Buffer I/O,
  // helper execution, confirmations, and UI state remain production code.
  await browser.execute(file=>{
    const api=window.__TAURI_INTERNALS__;
    if(!api?.invoke)throw new Error('Not a native Tauri webview');
    // Tauri freezes invoke. Intercept only the native picker's protocol reply;
    // all other IPC requests still reach the installed Rust backend.
    window.__xgecuTestOriginalFetch ||= window.fetch.bind(window);
    window.fetch=(input,init)=>{
      const url=decodeURIComponent(typeof input==='string'?input:input.url);
      if(/\/plugin:dialog\|(open|save)$/.test(url))return Promise.resolve(new Response(JSON.stringify(file),{headers:{'Content-Type':'application/json','Tauri-Response':'ok'}}));
      return window.__xgecuTestOriginalFetch(input,init);
    };
  },file);
}
async function screenshot(name){await browser.saveScreenshot(join('screenshots',process.env.XGECU_E2E_VARIANT||'installed',`${name}.png`));}
async function appearance(theme){await $('button[aria-label="Chip database settings"]').click();await $('select[aria-label="Appearance"]').selectByAttribute('value',theme);await browser.waitUntil(async()=>await $('html').getAttribute('data-theme')===theme);await $('button[aria-label="Chip database settings"]').click();}

describe('Installed XGecu Pro (no programmer connected)',()=>{
  it('opens the real workspace and reports a missing programmer',async()=>{
    await $('#tab-program').waitForDisplayed();
    await expect($('h2=Program a chip')).toBeDisplayed();
    await expect($('button=Program and Verify…')).toBeDisabled();
    await screenshot('01-start');
    await $('button=Connect / Refresh').click();
    await browser.waitUntil(async()=>/Error:/.test(await status().getText()),{timeout:30_000});
    await expect(status()).toHaveText(expect.stringMatching(/USB|programmer|T76|usb/i));
    await expect($('button=Program and Verify…')).toBeDisabled();
    await screenshot('02-no-programmer');
  });

  it('loads the real pinned catalog, selects a chip, and persists its favorite',async()=>{
    await $('button=Browse All Chips').click();
    await browser.waitUntil(async()=>/Catalog loaded:/.test(await status().getText()),{timeout:90_000});
    const search=await $('input[aria-label="Search chip database"]');
    await search.setValue('MX25L51245G');
    const chip=await $('button[title="MX25L51245G@SOIC16"]');
    await chip.waitForDisplayed();await chip.click();
    await browser.waitUntil(async()=>/Chip details loaded/.test(await status().getText()));
    await expect($('.program h3')).toHaveText('MX25L51245G@SOIC16');
    const existing=await $('button[aria-label="Remove from favorites: MX25L51245G@SOIC16"]');
    if(await existing.isExisting())await existing.click();
    await $('button[aria-label="Add to favorites: MX25L51245G@SOIC16"]').click();
    await $('button[aria-label="Remove from favorites: MX25L51245G@SOIC16"]').waitForDisplayed();
    await browser.refresh();
    await $('button[aria-label="Remove from favorites: MX25L51245G@SOIC16"]').waitForDisplayed();
    await expect($('button=Program and Verify…')).toBeDisabled();
    await screenshot('03-catalog');
  });

  it('uses the native HEX backend, protects unsaved changes, and saves atomically',async()=>{
    await $('#tab-hex').click();
    await chooseFile(nativeFile('editor-source.bin'));
    await $('button=Open File…').click();
    await browser.waitUntil(async()=>/Image loaded: editor-source.bin, 256 bytes/.test(await status().getText()));
    await expect($('.hex-bytes')).toHaveText(expect.stringContaining('00 01 02 03'));
    await $('summary=Edit buffer').click();
    await $('input[aria-label="Byte address"]').setValue('0');
    await $('input[aria-label="Byte value"]').setValue('AB');
    await $('button=Set Byte').click();
    await browser.waitUntil(async()=>/Buffer modified/.test(await status().getText()));
    await expect($('.hex-bytes')).toHaveText(expect.stringContaining('AB 01 02 03'));
    await chooseFile(nativeFile('editor-other.bin'));
    await $('button=Open File…').click();
    await $('dialog').waitForDisplayed();
    await expect($('button=Cancel')).toBeFocused();
    await browser.keys('Enter');
    await $('dialog').waitForExist({reverse:true});
    await expect($('.hex-bytes')).toHaveText(expect.stringContaining('AB 01 02 03'));
    await $('button=Undo').click();
    await browser.waitUntil(async()=>(await $('.hex-bytes').getText()).includes('00 01 02 03'));
    await $('button=Redo').click();
    await browser.waitUntil(async()=>(await $('.hex-bytes').getText()).includes('AB 01 02 03'));
    await chooseFile(nativeFile('editor-saved.bin'));
    await $('button=Save As…').click();
    await browser.waitUntil(async()=>/Buffer saved: editor-saved.bin/.test(await status().getText()));
    assert.equal(readFileSync(resolve('test-results/editor-source.bin'))[0],0);
    assert.equal(readFileSync(resolve('test-results/editor-saved.bin'))[0],0xab);
    await screenshot('04-hex-editor');
  });

  it('supports keyboard workspace navigation and dark compact layout',async()=>{
    await $('#tab-hex').click();await browser.keys('End');
    await expect($('#tab-activity')).toHaveAttribute('aria-selected','true');
    await browser.keys('Home');await expect($('#tab-program')).toHaveAttribute('aria-selected','true');
    await appearance('dark');
    await browser.setWindowSize(1020,680);
    await screenshot('05-dark-compact');
    const bounds=await browser.execute(()=>{
      const panel=document.querySelector('.tab-panel').getBoundingClientRect();
      const footer=document.querySelector('.operation-status').getBoundingClientRect();
      return {width:innerWidth,height:innerHeight,panelBottom:panel.bottom,footerTop:footer.top,footerBottom:footer.bottom,scroll:document.documentElement.scrollWidth};
    });
    assert.ok(bounds.panelBottom<=bounds.footerTop+1,'Status must not overlap the workspace');
    assert.ok(bounds.footerBottom<=bounds.height+1,'Status must remain visible');
    assert.ok(bounds.scroll<=bounds.width+1,'No horizontal clipping at the minimum size');
    await browser.execute(()=>{document.documentElement.style.zoom='1.25'});
    const scaled=await browser.execute(()=>{
      const footer=document.querySelector('.operation-status').getBoundingClientRect();
      return {bottom:footer.bottom,height:innerHeight,width:innerWidth,scroll:document.documentElement.scrollWidth};
    });
    assert.ok(scaled.bottom<=scaled.height+1,'Status remains visible at 125% content scale');
    assert.ok(scaled.scroll<=scaled.width+1,'No horizontal clipping at 125% content scale');
    await screenshot('05-dark-compact-scale-125');
    await browser.execute(()=>{document.documentElement.style.zoom='1'});
  });

  it('runs real no-device USB diagnostics and exports its report',async()=>{
    await $('button=USB Diagnostics…').click();
    await $('dialog').waitForDisplayed();
    await $('button=Test Connection').click();
    await $('button=New Test').waitForEnabled();
    await $('summary=Technical report').click();
    const report=await $('.technical-report').getText();
    assert.equal(JSON.parse(report).report.passed,false);
    assert.ok(JSON.parse(report).report.error);
    await chooseFile(nativeFile('usb-report.json'));
    await $('button=Save Report…').click();
    await browser.waitUntil(async()=>/USB report saved/.test(await status().getText()));
    const saved=JSON.parse(readFileSync(resolve('test-results/usb-report.json'),'utf8'));
    assert.equal(saved.report.passed,false);assert.equal(saved.report.opening?.interface_claimed??false,false);
    await screenshot('06-usb-no-device');
    await $('button=Close').click();
  });
});
