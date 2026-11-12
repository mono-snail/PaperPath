import { createRequire } from 'node:module';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
const req=createRequire('/Users/yanjun/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/');
const {createCanvas,loadImage,GlobalFonts}=req('@napi-rs/canvas');
const sharp=req('sharp');
GlobalFonts.registerFromPath('/System/Library/Fonts/Supplemental/Georgia.ttf','PP Serif');
GlobalFonts.registerFromPath('/System/Library/Fonts/Supplemental/Arial.ttf','PP Sans');
GlobalFonts.registerFromPath('/System/Library/AssetsV2/com_apple_MobileAsset_Font8/86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc','PP Chinese');
async function screenshotImage(file){return loadImage(await sharp(file).autoOrient().png().toBuffer());}
const root=process.cwd(),out=path.join(root,'design/app-store-2026-11-02/store-assets');await fs.mkdir(out,{recursive:true});
const palette=[['#F4EFE8','#152A38'],['#152A38','#F4EFE8'],['#DCE9ED','#152A38']];
const sourceDir='design/excellence-2026-10-30';
const panels=[
 {key:'library',en:['Your documents.','A little calmer.'],zh:['重要文件，','从容整理。'],tone:0},
 {key:'tools',en:['Fill. Sign.','Keep moving.'],zh:['填写，签名。','接着往前。'],tone:1},
 {key:'text',en:['Read at','your own pace.'],zh:['舒适阅读，','按你的节奏。'],tone:2}
];
const manifest=[];
function rr(ctx,x,y,w,h,r){ctx.beginPath();ctx.roundRect(x,y,w,h,r);}
function embed(ctx,img,x,y,w){const h=w*img.height/img.width;ctx.save();ctx.shadowColor='#00000025';ctx.shadowBlur=40;ctx.shadowOffsetY=20;ctx.fillStyle='#17252e';rr(ctx,x-9,y-9,w+18,h+18,36);ctx.fill();ctx.restore();ctx.drawImage(img,x,y,w,h);return h;}
async function write(c,file,info){const data=c.toBuffer('image/png');await fs.writeFile(path.join(out,file),data);manifest.push({file,width:c.width,height:c.height,...info,sha256:crypto.createHash('sha256').update(data).digest('hex')});}
for(const locale of ['en-US','zh-Hans'])for(const device of ['iphone','ipad'])for(let i=0;i<panels.length;i++){
 const p=panels[i],zh=locale==='zh-Hans',ipad=device==='ipad';
 // Chinese captures intentionally show the app's actual larger text mode. No UI pixels are translated.
 const src=`${sourceDir}/${ipad?'ipad-light':zh?'phone-dark-zh-ax':'phone-light'}-${p.key}.png`;
 const img=await screenshotImage(path.join(root,src)),w=ipad?2752:1320,h=ipad?2064:2868;
 const c=createCanvas(w,h),ctx=c.getContext('2d'),[bg,fg]=palette[p.tone];ctx.fillStyle=bg;ctx.fillRect(0,0,w,h);ctx.fillStyle=fg;
 const m=ipad?130:100;ctx.font=`${ipad?72:54}px "PP Serif"`;ctx.fillText('PaperPath',m,ipad?170:155);
 const lines=zh?p.zh:p.en;let size=ipad?125:132;ctx.font=`${size}px "${zh?'PP Chinese':'PP Serif'}"`;
 const tw=ipad?900:w-2*m;while(Math.max(...lines.map(t=>ctx.measureText(t).width))>tw){size--;ctx.font=`${size}px "${zh?'PP Chinese':'PP Serif'}"`;}
 const y=ipad?620:360;lines.forEach((line,j)=>ctx.fillText(line,m,y+j*size*1.18));
 if(ipad){let sw=1550;if(sw*img.height/img.width>h-220)sw=(h-220)*img.width/img.height;embed(ctx,img,w-sw-95,(h-sw*img.height/img.width)/2,sw);}
 else{let sh=h-800,sw=sh*img.width/img.height;embed(ctx,img,(w-sw)/2,710,sw);}
 ctx.fillStyle=fg;ctx.globalAlpha=.65;ctx.font=`${ipad?30:26}px "PP Sans", "PP Chinese"`;
 const note=ipad?(zh?'iPad 实际界面 · 英文':'Actual iPad interface'):(zh?'实际界面 · 更大文字':'Actual app interface');ctx.fillText(note,m,h-48);ctx.globalAlpha=1;
 await write(c,`${device==='ipad'?'ipad-13':'iphone-large'}-${locale}-0${i+1}-${p.key}.png`,{locale,source:src,sourceUILanguage:ipad?'en':zh?'zh-Hans':'en',largerText:zh&&!ipad,wholeScreenshot:true,exifOrientationApplied:true,uiRetouched:false,captureDate:'2026-10-30',releaseRecapturePending:true});
}
// Title art contains real app screens, with no extra headline; Connect displays the title itself.
for(const [w,h] of [[5244,2950],[3840,1646]]){
 const c=createCanvas(w,h),ctx=c.getContext('2d');ctx.fillStyle='#F4EFE8';ctx.fillRect(0,0,w,h);
 const img=await screenshotImage(path.join(root,sourceDir,'ipad-light-library.png')),phone=await screenshotImage(path.join(root,sourceDir,'phone-light-tools.png'));
 const padW=Math.min(w*.69,h*.82*img.width/img.height),padH=padW*img.height/img.width,px=w*.07,py=(h-padH)/2;
 embed(ctx,img,px,py,padW);let ph=h*.84,pw=ph*phone.width/phone.height;embed(ctx,phone,w-pw-w*.06,h*.08,pw);
 await write(c,`title-${w}x${h}.png`,{source:[`${sourceDir}/ipad-light-library.png`,`${sourceDir}/phone-light-tools.png`],wholeScreenshot:true,exifOrientationApplied:true,uiRetouched:false,releaseRecapturePending:true});
}
for(const item of [...manifest].filter(m=>m.file.startsWith('iphone-large'))){const file=item.file.replace('iphone-large','iphone-medium'); const p=panels.find(p=>file.includes(p.key)); const data=await sharp(path.join(out,item.file)).resize(1206,2622,{fit:'contain',background:palette[p.tone][0]}).png().toBuffer();await fs.writeFile(path.join(out,file),data);manifest.push({...item,file,width:1206,height:2622,sha256:crypto.createHash('sha256').update(data).digest('hex')});}
const sources=[...new Set(manifest.flatMap(m=>m.source))];const provenance=await Promise.all(sources.map(async file=>({file,sha256:crypto.createHash('sha256').update(await fs.readFile(path.join(root,file))).digest('hex')})));
await fs.writeFile(path.join(out,'manifest.json'),JSON.stringify({palette,generatedBy:'tools/GenerateReleaseStoreAssets.mjs',sources:provenance,assets:manifest},null,2)+'\n');
const c=createCanvas(1680,1320),ctx=c.getContext('2d');ctx.fillStyle='#ddd8d0';ctx.fillRect(0,0,c.width,c.height);
for(let i=0;i<12;i++){const item=manifest[i],img=await loadImage(path.join(out,item.file)),x=30+(i%6)*275,y=35+Math.floor(i/6)*650;let s=Math.min(245/img.width,590/img.height);ctx.drawImage(img,x,y,img.width*s,img.height*s);ctx.fillStyle='#152a38';ctx.font='17px "PP Sans"';ctx.fillText(item.file.startsWith('ipad')?'iPad · '+item.locale:'iPhone · '+item.locale,x,y+620);}
await fs.writeFile(path.join(out,'contact-sheet.jpg'),await sharp(c.toBuffer('image/png')).jpeg({quality:90}).toBuffer());
console.log(JSON.stringify({count:manifest.length,out}));
