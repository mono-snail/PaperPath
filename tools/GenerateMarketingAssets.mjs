import { createRequire } from 'node:module';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

// Uses the bundled Codex graphics runtime; no browser or generated UI is involved.
const require = createRequire('/Users/yanjun/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/');
const { createCanvas, loadImage, GlobalFonts } = require('@napi-rs/canvas');
const sharp = require('sharp');
GlobalFonts.registerFromPath('/System/Library/Fonts/Supplemental/Arial Bold.ttf', 'Launch Sans');
GlobalFonts.registerFromPath('/System/Library/Fonts/Supplemental/Arial.ttf', 'Launch Text');
GlobalFonts.registerFromPath('/System/Library/AssetsV2/com_apple_MobileAsset_Font8/86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc', 'Launch CJK');
GlobalFonts.registerFromPath('/System/Library/Fonts/Supplemental/Georgia.ttf', 'Launch Serif');

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'design/launch-2026-10-26/store-assets');
await fs.mkdir(out, { recursive: true });
const colors = { navy:'#122b3b', ocean:'#00658b', paper:'#f7f6f3', mint:'#a7ddc7' };
const sources = {
  home:'design/ui-implementation-2026-10-26/iphone-home-final-light.png',
  privacy:'design/app-signature-50-2026-09-27/phone-light-privacy-review.png',
  verified:'design/app-signature-50-2026-09-27/phone-light-verified-copy.png',
  ocr:'design/app-signature-50-2026-09-27/phone-ocr.png',
  ipadTools:'design/ui-implementation-2026-10-26/ipad-document-tools.png',
  ipadHome:'design/ui-implementation-2026-10-26/ipad-home-final-dark.png',
};
const images = Object.fromEntries(await Promise.all(Object.entries(sources).map(async ([key, src]) => [key, await loadImage(path.join(root,src))])));
const panels = [
  {key:'home', name:'01-on-device', en:['Your PDFs.','Your device.'], zh:['你的 PDF，','留在你的设备。'], subEn:'Read · Organize · Process locally', subZh:'阅读 · 整理 · 本地处理', bg:'navy'},
  {key:'privacy', name:'02-private-details', en:['Private details.','Your call.'], zh:['分享之前，','先检查隐私。'], subEn:'Review sensitive details before sharing', subZh:'检查敏感信息，再决定永久涂黑', bg:'ocean'},
  {key:'verified', name:'03-verified-copy', en:['Redact. Verify.','Then share.'], zh:['永久涂黑。','验证后分享。'], subEn:'Share a verified copy. Keep the original.', subZh:'分享验证副本，保留原始文件', bg:'navy'},
  {key:'ocr', name:'04-searchable-text', en:['From scanned','to searchable.'], zh:['让扫描文档，','也能搜索。'], subEn:'Recognize text. Create a searchable copy.', subZh:'识别文字，创建可搜索的 PDF 副本', bg:'ocean'},
  {key:'ipadTools', name:'01-document-workspace', en:['Room for your','whole workflow.'], zh:['宽阔视野，','专注文档。'], subEn:'Read · Fill · Sign · Organize · Verify', subZh:'阅读 · 填写 · 签名 · 整理 · 验证', bg:'navy', ipad:true},
  {key:'ipadHome', name:'02-ipad-library', en:['A clear view.','Even after dark.'], zh:['深色模式，','清晰有序。'], subEn:'Your document library, with a page preview', subZh:'文档资料库与页面预览，一目了然', bg:'ocean', ipad:true},
];

function rounded(ctx,x,y,w,h,r) { ctx.beginPath();ctx.roundRect(x,y,w,h,r); }
function background(ctx,w,h,tone) {
  ctx.fillStyle=colors[tone];ctx.fillRect(0,0,w,h);
  const g=ctx.createLinearGradient(0,0,w,h);g.addColorStop(0,'#ffffff05');g.addColorStop(1,'#00000029');ctx.fillStyle=g;ctx.fillRect(0,0,w,h);
  // Large offset paper contours give the series a quiet, document-specific rhythm.
  ctx.save();ctx.translate(w*.54,h*.61);ctx.rotate(-.13);
  for(let i=0;i<3;i++) {ctx.strokeStyle=`rgba(167,221,199,${.08-i*.014})`;ctx.lineWidth=2;rounded(ctx,-w*.21+i*42,-h*.25+i*36,w*.8,h*.66,60);ctx.stroke();}
  ctx.restore();
}
function wordmark(ctx,x,y,size) {
  ctx.fillStyle=colors.paper;ctx.font=`${size}px "Launch Serif"`;ctx.fillText('PaperPath',x,y);
}
function label(ctx,str,x,y,size,color=colors.paper) {ctx.fillStyle=color;ctx.font=`${size}px "Launch Text", "Launch CJK"`;ctx.fillText(str,x,y);}
function screen(ctx,img,x,y,w,h,r=10) {
  ctx.save();ctx.shadowColor='#00000055';ctx.shadowBlur=65;ctx.shadowOffsetY=22;
  ctx.fillStyle='#dce3e2';rounded(ctx,x-8,y-8,w+16,h+16,r+7);ctx.fill();ctx.restore();
  // Screenshot is embedded whole, without cropping, masking, UI retouching or overlays.
  ctx.drawImage(img,x,y,w,h);
}
const manifest=[];
for(const locale of ['en-US','zh-Hans']) for(const panel of panels) {
  const w=panel.ipad?2064:1206,h=panel.ipad?2752:2622;
  const c=createCanvas(w,h),ctx=c.getContext('2d');background(ctx,w,h,panel.bg);
  const m=panel.ipad?130:88;
  wordmark(ctx,m,panel.ipad?145:132,panel.ipad?66:52);
  label(ctx,panel.ipad?'iPad':'iPhone',w-m-(panel.ipad?175:150),panel.ipad?145:132,panel.ipad?36:30,colors.mint);
  const lines=locale==='en-US'?panel.en:panel.zh;
  let size=panel.ipad?164:112;
  const family=locale==='en-US'?'Launch Sans':'Launch CJK';
  ctx.font=`${locale==='zh-Hans'?'600 ':''}${size}px "${family}"`;
  while(Math.max(...lines.map(s=>ctx.measureText(s).width))>w-m*2) {size--;ctx.font=`${locale==='zh-Hans'?'600 ':''}${size}px "${family}"`;}
  const baseline=panel.ipad?340:306, lineHeight=size*1.13;
  lines.forEach((line,i)=> {ctx.fillStyle=i?colors.mint:colors.paper;ctx.fillText(line,m,baseline+i*lineHeight);});
  label(ctx,locale==='en-US'?panel.subEn:panel.subZh,m,panel.ipad?625:535,panel.ipad?43:34);
  const img=images[panel.key];
  const targetHeight=panel.ipad?1920:1840;
  const targetWidth=targetHeight*img.width/img.height;
  screen(ctx,img,(w-targetWidth)/2,panel.ipad?730:680,targetWidth,targetHeight);
  const filename=`${panel.ipad?'ipad-13':'iphone-medium'}-${locale}-${panel.name}.png`;
  await fs.writeFile(path.join(out,filename),c.toBuffer('image/png'));
  manifest.push({file:filename,width:w,height:h,locale,source:sources[panel.key],sourceUILanguage:'en',fullScreenshotEmbedded:true});
}

// Social preview: real product screen, type and vector contours only.
{
  const c=createCanvas(1200,630),ctx=c.getContext('2d');background(ctx,1200,630,'navy');
  wordmark(ctx,62,82,38);
  ctx.font='64px "Launch Sans"';ctx.fillStyle=colors.paper;ctx.fillText('Your PDFs.',62,225);
  ctx.fillStyle=colors.mint;ctx.fillText('Your device.',62,302);
  label(ctx,'Read. Organize. Redact. Verify.',64,368,24);
  label(ctx,'PDF tools for iPhone and iPad',64,409,22,'#c6d2d5');
  ctx.fillStyle=colors.mint;ctx.fillRect(64,471,38,3);
  label(ctx,'ON-DEVICE DOCUMENT WORK',117,480,15,colors.mint);
  const img=images.verified,sh=545,sw=sh*img.width/img.height;
  screen(ctx,img,790,43,sw,sh,10);
  const filename='paperpath-og-en.png';await fs.writeFile(path.join(out,filename),c.toBuffer('image/png'));
  manifest.push({file:filename,width:1200,height:630,locale:'en-US',source:sources.verified,sourceUILanguage:'en',fullScreenshotEmbedded:true});
}
const sourceManifest=await Promise.all(Object.entries(sources).map(async([key,file])=>({key,file,sha256:crypto.createHash('sha256').update(await fs.readFile(path.join(root,file))).digest('hex')})));
await fs.writeFile(path.join(out,'manifest.json'),JSON.stringify({generatedBy:'tools/GenerateMarketingAssets.mjs',palette:colors,sources:sourceManifest,assets:manifest},null,2)+'\n');
const thumbW=280, thumbH=650,gap=24,cols=6,rows=2;
const contact=createCanvas(cols*(thumbW+gap)+gap,rows*(thumbH+gap)+130),ct=contact.getContext('2d');ct.fillStyle='#e8e8e3';ct.fillRect(0,0,contact.width,contact.height);
ct.fillStyle=colors.navy;ct.font='30px "Launch Sans"';ct.fillText('PaperPath / App Store screenshot review',24,47);
for(let i=0;i<12;i++) {
  const item=manifest[i],img=await loadImage(path.join(out,item.file)),x=gap+(i%cols)*(thumbW+gap),y=85+Math.floor(i/cols)*(thumbH+gap);
  const factor=Math.min(thumbW/img.width,(thumbH-40)/img.height);ct.drawImage(img,x,y,img.width*factor,img.height*factor);
  ct.fillStyle=colors.navy;ct.font='15px "Launch Text"';ct.fillText(`${item.locale} · ${item.file.split('-').slice(-3).join('-')}`,x,y+thumbH-15,thumbW);
}
await fs.writeFile(path.join(out,'contact-sheet.jpg'),await sharp(contact.toBuffer('image/png')).jpeg({quality:90}).toBuffer());
await fs.writeFile(path.join(out,'README.md'),`# PaperPath launch compositions\n\n12 App Store PNGs: 4 iPhone and 2 iPad images for each of en-US and zh-Hans. iPhone: 1206 × 2622; iPad: 2064 × 2752. Social preview: 1200 × 630.\n\nThese are marketing compositions using whole actual app screenshots, embedded without editing UI pixels. No synthetic UI, pricing text, free trial or subscription claims appear in the App Store images. Examples use fictional documents. Navy, ocean, paper and mint match the app direction.\n\n## Release gates\n\n- All screenshots currently show English app UI, including the zh-Hans compositions. Recapture actual Simplified Chinese UI and rerun with updated sources before submitting the Chinese localization. Do not translate text inside screenshots by image retouching.\n- Privacy, verified-copy and OCR sources were captured on 2026-09-27. Recapture the final release build so App Store images exactly reflect the shipping version.\n- iPad screenshots include the simulator's Chinese system date; use the final intended locale and a consistent status bar for release capture.\n- Confirm the target device slot accepts these exact portrait dimensions in App Store Connect before upload.\n- Marketing language describes the visible workflows; verified redaction still requires the release team's functional validation.\n\n## Reproduce\n\nRun the bundled Node binary against tools/GenerateMarketingAssets.mjs from any directory. macOS Arial, Georgia and PingFang fonts are used. See manifest.json for source paths, SHA-256 hashes, output dimensions and locale.\n\nPreview: contact-sheet.jpg.\n`);
console.log(JSON.stringify({out,count:manifest.length,assets:manifest.map(({file,width,height})=>({file,width,height}))},null,2));
