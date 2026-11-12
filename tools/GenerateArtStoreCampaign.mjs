import {createRequire} from 'node:module';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
const require=createRequire('/Users/yanjun/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/');
const {createCanvas,loadImage,GlobalFonts}=require('@napi-rs/canvas');
const sharp=require('sharp');
const root=process.cwd(),base='design/app-store-2026-11-03-art',out=path.join(root,base,'final');
await fs.mkdir(out,{recursive:true});
for(const [f,n] of [['Georgia.ttf','Art Serif'],['Arial.ttf','Art Sans'],['Songti.ttc','Art Song']])
 if(!GlobalFonts.registerFromPath('/System/Library/Fonts/Supplemental/'+f,n))throw Error('Missing local font: '+f);
GlobalFonts.registerFromPath('/System/Library/AssetsV2/com_apple_MobileAsset_Font8/86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc','Art Chinese');
const sources=new Map(),assets=[],checks=[];
const digest=b=>crypto.createHash('sha256').update(b).digest('hex');
async function get(file){const b=await fs.readFile(path.join(root,file));sources.set(file,digest(b));return loadImage(await sharp(b).autoOrient().png().toBuffer());}
const art={};for(const k of ['ivory','ink','pearl'])art[k]=await get(`${base}/assets/${k}.png`);
function cover(ctx,img,w,h,flip=false){ctx.save();if(flip){ctx.translate(w,0);ctx.scale(-1,1);}const s=Math.max(w/img.width,h/img.height),dw=img.width*s,dh=img.height*s;ctx.drawImage(img,(w-dw)/2,(h-dh)/2,dw,dh);ctx.restore();}
function round(ctx,x,y,w,h,r){ctx.beginPath();ctx.roundRect(x,y,w,h,r);}
function device(ctx,img,{x,y,w,angle=0,tablet=false},canvas){
 const h=w*img.height/img.width,r=tablet?43:68,b=tablet?14:13,a=angle*Math.PI/180;
 const corners=[[-w/2,-h/2],[w/2,-h/2],[w/2,h/2],[-w/2,h/2]].map(([px,py])=>({x:x+w/2+px*Math.cos(a)-py*Math.sin(a),y:y+h/2+px*Math.sin(a)+py*Math.cos(a)}));
 const bounds={left:Math.min(...corners.map(p=>p.x)),right:Math.max(...corners.map(p=>p.x)),top:Math.min(...corners.map(p=>p.y)),bottom:Math.max(...corners.map(p=>p.y))};
 if(bounds.left<20||bounds.right>canvas.width-20||bounds.top<20||bounds.bottom>canvas.height-70)throw Error('Screenshot out of canvas '+JSON.stringify(bounds));
 ctx.save();ctx.translate(x+w/2,y+h/2);ctx.rotate(a);ctx.translate(-w/2,-h/2);
 ctx.shadowColor='#07172470';ctx.shadowBlur=65;ctx.shadowOffsetX=18;ctx.shadowOffsetY=42;
 round(ctx,-b,-b,w+b*2,h+b*2,r+b);ctx.fillStyle='#25333d';ctx.fill();ctx.shadowColor='transparent';
 const edge=ctx.createLinearGradient(-b,0,w+b,h);edge.addColorStop(0,'#e9eef0');edge.addColorStop(.22,'#53616a');edge.addColorStop(.5,'#e7edef');edge.addColorStop(.8,'#35434e');edge.addColorStop(1,'#bfcbd0');
 ctx.strokeStyle=edge;ctx.lineWidth=5;ctx.stroke();
 round(ctx,-6,-6,w+12,h+12,r+6);ctx.fillStyle='#111b23';ctx.fill();
 ctx.save();round(ctx,0,0,w,h,r);ctx.clip();ctx.drawImage(img,0,0,w,h);ctx.restore();
 round(ctx,0,0,w,h,r);ctx.strokeStyle='#ffffff70';ctx.lineWidth=1.5;ctx.stroke();ctx.restore();
 return {x,y,width:w,height:h,angle,bounds,displayCornerMask:true};
}
function text(ctx,t,x,y,size,family,color,maxWidth){ctx.fillStyle=color;ctx.font=`${size}px "${family}"`;while(ctx.measureText(t).width>maxWidth&&size>20){size--;ctx.font=`${size}px "${family}"`;}ctx.fillText(t,x,y);return {text:t,x,y,size,width:ctx.measureText(t).width};}
async function save(c,file,meta){const b=await sharp(c.toBuffer('image/png')).removeAlpha().png().toBuffer();await fs.writeFile(path.join(out,file),b);assets.push({file,width:c.width,height:c.height,...meta,sha256:digest(b)});}
const phone=[
 {key:'hero',tone:'ivory',angle:-5,x:252,w:822,y:825,en:['Your PDFs.','Beautifully handled.'],zh:['重要文件，','漂亮收尾。'],eyebrow:['READ · SIGN · REDACT · OCR','阅读 · 签名 · 涂黑 · 文字识别']},
 {key:'privacy',tone:'ink',angle:4,x:210,w:820,y:825,en:['Private details.','Your decision.'],zh:['隐私，','由你决定。'],eyebrow:['PRIVACY REVIEW','隐私复核']},
 {key:'verified',tone:'pearl',angle:-3,x:250,w:815,y:830,en:['Keep the original.','Check your copy.'],zh:['保留原件，','检查再交付。'],eyebrow:['VERIFIED OUTPUT','检查交付副本']},
 {key:'library',tone:'ivory',angle:4,x:200,w:825,y:825,en:['Every document.','A clear view.'],zh:['繁杂文件，','清晰有序。'],eyebrow:['YOUR DOCUMENT DESK','你的文档工作台'],flip:true},
 {key:'tools',tone:'ink',angle:-4,x:255,w:820,y:825,en:['Fill. Sign.','Move forward.'],zh:['填写。签名。','一气呵成。'],eyebrow:['THE TOOLS TO FINISH','填表与签名'],flip:true},
 {key:'text',tone:'pearl',angle:3,x:215,w:815,y:830,en:['A little space.','A clearer read.'],zh:['给文字，','一点呼吸。'],eyebrow:['FOCUS READER','专注阅读'],flip:true}
];
for(const locale of ['en-US','zh-Hans'])for(let i=0;i<phone.length;i++){
 const p=phone[i],zh=locale==='zh-Hans',c=createCanvas(1320,2868),ctx=c.getContext('2d'),dark=p.tone==='ink',fg=dark?'#f9f6f0':'#102a3a';
 cover(ctx,art[p.tone],c.width,c.height,p.flip);text(ctx,'PaperPath',104,163,59,'Art Serif',fg,1100);
 text(ctx,p.eyebrow[zh?1:0],110,310,32,zh?'Art Chinese':'Art Sans',dark?'#b8d3e3':'#3f697d',1100);
 const lines=zh?p.zh:p.en;lines.forEach((t,j)=>text(ctx,t,104,490+j*167,zh?155:147,zh?'Art Song':'Art Serif',fg,1110));
 const src=`design/app-store-2026-11-02/screenshots/phone-en-${p.key}.png`,img=await get(src);
 const placement=device(ctx,img,p,c);
 text(ctx,zh?'实际 App 界面 · 英文示例':'Actual app interface',105,2810,25,zh?'Art Chinese':'Art Sans',dark?'#d9e6ed':'#26475a',1100);
 const meta={locale,device:'phone',feature:p.key,background:p.tone,source:src,sourceUILanguage:'en',captureDate:'2026-11-02',wholeScreenshot:true,uiRetouched:false,placement};
 const name=`iphone-large-${locale}-0${i+1}-${p.key}.png`;await save(c,name,meta);
 const b=await sharp(path.join(out,name)).resize(1206,2622,{fit:'contain',background:dark?'#102537':'#e6e8e6'}).removeAlpha().png().toBuffer();
 const medium=name.replace('iphone-large','iphone-medium');await fs.writeFile(path.join(out,medium),b);
 const scale=1206/1320,offsetY=(2622-2868*scale)/2;
 const mediumPlacement={...placement,x:placement.x*scale,y:placement.y*scale+offsetY,width:placement.width*scale,height:placement.height*scale,bounds:{left:placement.bounds.left*scale,right:placement.bounds.right*scale,top:placement.bounds.top*scale+offsetY,bottom:placement.bounds.bottom*scale+offsetY}};
 assets.push({file:medium,width:1206,height:2622,...meta,placement:mediumPlacement,sha256:digest(b)});
 checks.push({file:name,screenshotInsideCanvas:true,realUIUnretouched:true});
}
const pads=[
 {key:'hero',tone:'ivory',angle:-2,en:'Room for your whole workflow.',zh:'宽阔视野，从容处理。'},
 {key:'library',tone:'pearl',angle:2,en:'Every document. In view.',zh:'文档与预览，一目了然。'},
 {key:'tools',tone:'ink',angle:-2,en:'The right tools. Close at hand.',zh:'需要的工具，就在手边。'}
];
for(const locale of ['en-US','zh-Hans'])for(let i=0;i<pads.length;i++){
 const p=pads[i],zh=locale==='zh-Hans',c=createCanvas(2752,2064),ctx=c.getContext('2d'),fg=p.tone==='ink'?'#fffaf2':'#102a3a';cover(ctx,art[p.tone],c.width,c.height);
 text(ctx,'PaperPath',125,158,65,'Art Serif',fg,2500);text(ctx,zh?p.zh:p.en,120,370,zh?151:133,zh?'Art Song':'Art Serif',fg,2490);
 const src=`design/app-store-2026-11-02/screenshots/ipad-en-${p.key}.png`,img=await get(src),placement=device(ctx,img,{x:466,y:540,w:1820,angle:p.angle,tablet:true},c);
 text(ctx,zh?'实际 App 界面 · 英文示例':'Actual app interface',125,2018,28,zh?'Art Chinese':'Art Sans',fg,2400);
 await save(c,`ipad-13-${locale}-0${i+1}-${p.key}.png`,{locale,device:'ipad',feature:p.key,background:p.tone,source:src,wholeScreenshot:true,sourceUILanguage:'en',uiRetouched:false,placement});
}
const pad=await get('design/app-store-2026-11-02/screenshots/ipad-en-hero.png'),ph=await get('design/app-store-2026-11-02/screenshots/phone-en-hero.png');
for(const [w,h]of [[5244,2950],[3840,1646]]){
 const c=createCanvas(w,h),ctx=c.getContext('2d');cover(ctx,art.ivory,w,h);const small=h<2000;
 text(ctx,'PaperPath',w*.06,h*.18,small?164:250,'Art Serif','#102a3a',w*.85);
 const pw=small?1680:2700,px=small?1270:570,py=small?240:650;
 device(ctx,pad,{x:px,y:py,w:pw,angle:-3,tablet:true},c);
 const fw=small?535:930;device(ctx,ph,{x:small?2900:3850,y:small?225:500,w:fw,angle:4},c);
 await save(c,`title-${w}x${h}.png`,{device:'title',background:'ivory',source:['design/app-store-2026-11-02/screenshots/ipad-en-hero.png','design/app-store-2026-11-02/screenshots/phone-en-hero.png'],wholeScreenshot:true,uiRetouched:false});
}
const manifest={generator:'tools/GenerateArtStoreCampaign.mjs',imageTool:'Built-in image_gen',artDirection:'Documents, elevated — sculptural paper, ink navy, cobalt edge light',sources:[...sources].map(([file,sha256])=>({file,sha256})),assets,limitations:['All app UI is from actual English-language simulator captures, 2026-11-02. Chinese promotional typography is localized; captions explicitly identify the English interface example.','Generated material is independent background artwork, not generated app UI. Screenshot content and warnings are not retouched; screens are scaled, rotated, framed and corner-masked.','No Connect replacement/upload is implied by local generation. Existing approved files are preserved.']};
await fs.writeFile(path.join(out,'manifest.json'),JSON.stringify(manifest,null,2));
await fs.writeFile(path.join(out,'validation.json'),JSON.stringify({assets:assets.length,checks,allRGB:true},null,2));
const tiles=assets.filter(a=>a.file.startsWith('iphone-large'));
const contact=createCanvas(1920,1480),ct=contact.getContext('2d');ct.fillStyle='#dce1e3';ct.fillRect(0,0,1920,1480);
for(let i=0;i<tiles.length;i++){let im=await loadImage(path.join(out,tiles[i].file));ct.drawImage(im,20+(i%6)*317,20+Math.floor(i/6)*735,297,645);ct.fillStyle='#173247';ct.font='22px "Art Sans"';ct.fillText(tiles[i].locale+' / '+tiles[i].feature,22+(i%6)*317,700+Math.floor(i/6)*735);}
await fs.writeFile(path.join(out,'contact-sheet.jpg'),await sharp(contact.toBuffer('image/png')).jpeg({quality:94}).toBuffer());
const trio=createCanvas(1530,1108),tr=trio.getContext('2d');tr.fillStyle='#dce1e3';tr.fillRect(0,0,1530,1108);
for(let i=0;i<3;i++){let im=await loadImage(path.join(out,`iphone-large-zh-Hans-0${i+1}-${phone[i].key}.png`));tr.drawImage(im,10+i*507,10,500,1086);}
await fs.writeFile(path.join(out,'hero-trio-zh.jpg'),await sharp(trio.toBuffer('image/png')).jpeg({quality:95}).toBuffer());
console.log(JSON.stringify({out,assets:assets.length}));
