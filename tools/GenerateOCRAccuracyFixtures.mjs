// Raster-only OCR fixtures from an existing local font; never downloads fonts or models.
import fs from 'node:fs/promises';
import {createRequire} from 'node:module';
import crypto from 'node:crypto';
const require=createRequire('/Users/yanjun/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/');
const {createCanvas,GlobalFonts}=require('@napi-rs/canvas');
const font='/System/Library/AssetsV2/com_apple_MobileAsset_Font8/86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc';
if(!GlobalFonts.registerFromPath(font,'OCR Chinese'))throw Error('Cached CJK font unavailable; no download allowed');
GlobalFonts.registerFromPath('/System/Library/Fonts/Supplemental/Arial.ttf','OCR English');
const source=await fs.readFile('PaperPathTests/PaperPathTests.swift','utf8');
function lines(name){const body=source.match(new RegExp('let '+name+' = \\[([\\s\\S]*?)\\n        \\]'))[1];return [...body.matchAll(/"([^"\n]*)"/g)].map(m=>m[1].replace(/\\u\{([0-9a-f]+)\}/gi,(_,hex)=>String.fromCodePoint(parseInt(hex,16))));}
const chinese=lines('chineseLines'),english=lines('englishLines');
const cases=[['chinese-11pt',chinese,11],['chinese-8pt',chinese,8],['english-8pt',english,8],['bilingual-10pt',chinese.flatMap((t,i)=>[t,english[i]]),10]];
const out='PaperPathTests/Fixtures/RealPDFCorpus/OCRAccuracyRaster';await fs.mkdir(out,{recursive:true});const images=[];
for(const [name,text,size]of cases){const scale=300/72,c=createCanvas(Math.round(595*scale),Math.round(842*scale)),ctx=c.getContext('2d');ctx.fillStyle='#fff';ctx.fillRect(0,0,c.width,c.height);ctx.scale(scale,scale);ctx.fillStyle='#000';ctx.font=`${size}px "OCR English", "OCR Chinese"`;ctx.textBaseline='top';text.forEach((line,i)=>ctx.fillText(line,48,60+i*27));const data=c.toBuffer('image/png');await fs.writeFile(`${out}/${name}.png`,data);images.push({file:name+'.png',fontPoints:size,width:c.width,height:c.height,dpi:300,text,sha256:crypto.createHash('sha256').update(data).digest('hex')});}
await fs.writeFile(`${out}/manifest.json`,JSON.stringify({generator:'tools/GenerateOCRAccuracyFixtures.mjs',reason:'Avoid simulator font fallback turning Chinese test inputs into empty square glyphs. Raster-only fixtures contain no text layer.',fontSource:font,fontSha256:crypto.createHash('sha256').update(await fs.readFile(font)).digest('hex'),images},null,2)+'\n');
console.log('Prepared four raster-only fixtures using cached fonts.');
