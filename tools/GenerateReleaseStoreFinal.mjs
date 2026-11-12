import {createRequire} from 'node:module';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
const require=createRequire('/Users/yanjun/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/');
const {createCanvas,loadImage,GlobalFonts}=require('@napi-rs/canvas');const sharp=require('sharp');
for(const [file,name] of [['Georgia.ttf','PP Serif'],['Arial.ttf','PP Sans'],['Songti.ttc','PP Song']]){if(!GlobalFonts.registerFromPath('/System/Library/Fonts/Supplemental/'+file,name))throw Error('Missing cached font '+file);}
GlobalFonts.registerFromPath('/System/Library/AssetsV2/com_apple_MobileAsset_Font8/86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc','PP Chinese');
const root=process.cwd(),out=path.join(root,'design/app-store-2026-11-02/store-final');await fs.mkdir(out,{recursive:true});const fresh='design/app-store-2026-11-02/screenshots',old='design/excellence-2026-10-30';
const colors=[['#F4EFE8','#152A38'],['#152A38','#F4EFE8'],['#DCE9ED','#152A38']];
const phone=[
 {key:'hero',tone:0,en:['Important PDFs.','Beautifully handled.'],zh:['重要文件，','从容完成。']},
 {key:'privacy',tone:1,en:['Private details.','Your decision.'],zh:['分享之前，','复核隐私。']},
 {key:'verified',tone:2,en:['Keep the original.','Check your copy.'],zh:['保留原件，','检查副本。']},
 {key:'library',tone:0,en:['Every document.','A clear view.'],zh:['重要文件，','从容整理。']},
 {key:'tools',tone:1,en:['Fill. Sign.','Keep moving.'],zh:['填写，签名。','接着往前。']},
 {key:'text',tone:2,en:['Read at','your own pace.'],zh:['放大文字，','清楚阅读。']}
];
const ipad=[
 {key:'hero',tone:0,en:['Room for your whole workflow.'],zh:['宽阔视野，从容处理。']},
 {key:'library',tone:2,en:['Every document. In view.'],zh:['文档与预览，一目了然。']},
 {key:'tools',tone:1,en:['The right tools. Close at hand.'],zh:['需要的工具，就在手边。']}
];
const assets=[];const sources=new Map();
async function imageFor(file){const raw=await fs.readFile(path.join(root,file));sources.set(file,crypto.createHash('sha256').update(raw).digest('hex'));return loadImage(await sharp(raw).autoOrient().png().toBuffer());}
function embed(ctx,img,x,y,w){const h=w*img.height/img.width;ctx.save();ctx.shadowColor='#00000020';ctx.shadowBlur=38;ctx.shadowOffsetY=18;ctx.fillStyle='#fff';ctx.fillRect(x-2,y-2,w+4,h+4);ctx.restore();ctx.drawImage(img,x,y,w,h);ctx.strokeStyle='#152a382b';ctx.lineWidth=2;ctx.strokeRect(x-1,y-1,w+2,h+2);return {x,y,width:w,height:h};}
async function save(c,file,meta){const data=await sharp(c.toBuffer('image/png')).removeAlpha().png().toBuffer();await fs.writeFile(path.join(out,file),data);assets.push({file,width:c.width,height:c.height,...meta,sha256:crypto.createHash('sha256').update(data).digest('hex')});}
for(const locale of ['en-US','zh-Hans'])for(const device of ['phone','ipad']){
 const zh=locale==='zh-Hans',tablet=device==='ipad',panels=tablet?ipad:phone;
 for(let i=0;i<panels.length;i++){
  const p=panels[i];let oldChinese=zh&&!tablet&&['library','tools','text'].includes(p.key);
  const src=oldChinese?`${old}/phone-dark-zh-ax-${p.key}.png`:`${fresh}/${device}-en-${p.key}.png`;
  const img=await imageFor(src),w=tablet?2752:1320,h=tablet?2064:2868,c=createCanvas(w,h),ctx=c.getContext('2d'),[bg,fg]=colors[p.tone];ctx.fillStyle=bg;ctx.fillRect(0,0,w,h);ctx.fillStyle=fg;
  const m=tablet?130:100;ctx.font=`${tablet?67:54}px "PP Serif"`;ctx.fillText('PaperPath',m,tablet?155:155);
  let size=tablet?136:133;const lines=zh?p.zh:p.en;ctx.font=`${size}px "${zh?'PP Song':'PP Serif'}"`;
  while(Math.max(...lines.map(s=>ctx.measureText(s).width))>w-2*m){size--;ctx.font=`${size}px "${zh?'PP Song':'PP Serif'}"`;}
  lines.forEach((t,j)=>ctx.fillText(t,m,(tablet?360:355)+j*size*1.2));
  const sh=tablet?1430:2050,sw=sh*img.width/img.height;const screenshotRect=embed(ctx,img,(w-sw)/2,tablet?490:710,sw);
  ctx.globalAlpha=.65;ctx.font=`${tablet?29:26}px "PP Sans", "PP Chinese"`;
  ctx.fillText(zh?(oldChinese?'实际界面 · 更大文字':'实际界面 · 英文示例'):(p.key==='hero'?'Actual app · Fictional sample':'Actual app interface'),m,h-44);ctx.globalAlpha=1;
  const meta={locale,device,feature:p.key,source:src,sourceUILanguage:oldChinese?'zh-Hans':'en',captureDate:oldChinese?'2026-10-30':'2026-11-02',largerText:oldChinese,wholeScreenshot:true,exifOrientationApplied:true,uiRetouched:false,screenshotRect};
  const name=`${tablet?'ipad-13':'iphone-large'}-${locale}-0${i+1}-${p.key}.png`;await save(c,name,meta);
  if(!tablet){const mediumName=name.replace('iphone-large','iphone-medium'),data=await sharp(path.join(out,name)).resize(1206,2622,{fit:'contain',background:bg}).removeAlpha().png().toBuffer();await fs.writeFile(path.join(out,mediumName),data);assets.push({file:mediumName,width:1206,height:2622,...meta,sha256:crypto.createHash('sha256').update(data).digest('hex')});}
 }
}
for(const [w,h]of [[5244,2950],[3840,1646]]){
 const c=createCanvas(w,h),ctx=c.getContext('2d');ctx.fillStyle=colors[0][0];ctx.fillRect(0,0,w,h);const pad=await imageFor(`${fresh}/ipad-en-hero.png`),ph=await imageFor(`${fresh}/phone-en-hero.png`);const pw=Math.min(w*.68,h*.82*pad.width/pad.height),hh=pw*pad.height/pad.width;embed(ctx,pad,w*.06,(h-hh)/2,pw);const phoneH=h*.84,phoneW=phoneH*ph.width/ph.height;embed(ctx,ph,w-phoneW-w*.06,h*.08,phoneW);
 await save(c,`title-${w}x${h}.png`,{source:[`${fresh}/ipad-en-hero.png`,`${fresh}/phone-en-hero.png`],sourceUILanguage:'en',captureDate:'2026-11-02',wholeScreenshot:true,uiRetouched:false});
}
await fs.writeFile(path.join(out,'manifest.json'),JSON.stringify({generator:'tools/GenerateReleaseStoreFinal.mjs',palette:colors,sources:[...sources].map(([file,sha256])=>({file,sha256})),assets,limitations:['Chinese library, tools and text screens use authentic 2026-10-30 accessibility-size captures; production UI source matches that baseline. Other screens show the actual English interface captured on 2026-11-02.','Image tool proposal is not used as app UI. No screenshot UI pixels or warnings are retouched.']},null,2)+'\n');
const review=[...assets.filter(a=>a.file.startsWith('iphone-large-en-US')),...assets.filter(a=>a.file.startsWith('iphone-large-zh-Hans')),...assets.filter(a=>a.file.startsWith('ipad-13'))];
const c=createCanvas(1740,1570),ctx=c.getContext('2d');ctx.fillStyle='#dfd9d0';ctx.fillRect(0,0,c.width,c.height);
for(let i=0;i<review.length;i++){const a=review[i],img=await loadImage(path.join(out,a.file)),x=30+(i%6)*285,y=25+Math.floor(i/6)*640,s=Math.min(260/img.width,565/img.height);ctx.drawImage(img,x,y,img.width*s,img.height*s);ctx.fillStyle='#152a38';ctx.font='17px "PP Sans"';ctx.fillText(a.locale+' / '+a.feature,x,y+(i<12?600:235));}
await fs.writeFile(path.join(out,'contact-sheet.jpg'),await sharp(c.toBuffer('image/png')).jpeg({quality:92}).toBuffer());console.log(JSON.stringify({out,count:assets.length}));
