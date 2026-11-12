// Render the actual local website with the bundled browser runtime.
const {chromium}=require('/Users/yanjun/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const path=require('path');const fs=require('fs');
(async()=>{const browser=await chromium.launch({channel:'chrome',headless:true});
const results=[];const out=path.resolve(__dirname,'../design/hero-2026-10-28');
for(const [name,route,width,height] of [['desktop-zh','/',1440,900],['desktop-en','/en/',1440,900],['tablet-ja','/ja/',768,1000],['mobile-zh','/',390,844],['small-en','/en/',320,800]]){
 const page=await browser.newPage({viewport:{width,height},deviceScaleFactor:1});
 await page.goto('http://127.0.0.1:8769'+route,{waitUntil:'networkidle'});
 await page.screenshot({path:path.join(out,name+'.png'),fullPage:false});
 if(name==='mobile-zh')await page.locator('.hero').screenshot({path:path.join(out,'mobile-hero-full.png')});
 const state=await page.evaluate(()=>({viewport:innerWidth,content:document.documentElement.scrollWidth,broken:[...document.images].filter(i=>i.loading!=="lazy" && (!i.complete||!i.naturalWidth)).map(i=>i.src),heroImages:[...document.querySelectorAll('.hero-art img')].map(i=>({src:i.getAttribute('src'),natural:[i.naturalWidth,i.naturalHeight],display:[i.width,i.height]}))}));
 if(state.content>width||state.broken.length)throw Error(JSON.stringify({name,...state}));results.push({name,...state});
 await page.close();
}
await browser.close();fs.writeFileSync(path.join(out,'browser-check.json'),JSON.stringify(results,null,2)+'\n');console.log(JSON.stringify(results,null,2));})();
