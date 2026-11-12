// Export whole, real captures; normalize EXIF orientation and compress for the web.
const fs=require('fs');const path=require('path');const crypto=require('crypto');
const sharp=require('/Users/yanjun/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/sharp');
(async()=>{const root=path.resolve(__dirname,'..');const base=path.join(root,'design/hero-2026-10-28');const records=[];
for(const [key,folder,width] of [['ipad','ipad-final-attachments',1800],['phone','phone-attachments',900]]){
 const manifest=JSON.parse(fs.readFileSync(path.join(base,folder,'manifest.json'),'utf8'));
 const entry=manifest.flatMap(x=>x.attachments).find(x=>x.suggestedHumanReadableName.startsWith('hero-'+key+'_'));
 const source=path.join(base,folder,entry.exportedFileName);const output=path.join(root,'website/assets/launch','hero-'+key+'.webp');
 await sharp(source).rotate().resize({width,withoutEnlargement:true}).webp({quality:92}).toFile(output);
 const {width:w,height:h}=await sharp(output).metadata();
 records.push({device:key,udid:entry.deviceId,source:path.relative(root,source),sourceSHA256:crypto.createHash('sha256').update(fs.readFileSync(source)).digest('hex'),output:path.relative(root,output),width:w,height:h,wholeScreenshot:true,processing:'EXIF orientation normalization, resizing and WebP compression only'});
}
fs.writeFileSync(path.join(base,'assets-manifest.json'),JSON.stringify(records,null,2)+'\n');console.log(records);})();
