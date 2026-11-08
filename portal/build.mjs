import {cp,mkdir,readFile,writeFile,readdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=path.dirname(fileURLToPath(import.meta.url));
const version=(await readFile(path.join(root,'../VERSION'),'utf8').catch(()=> '7.14.0')).trim();
const out=path.resolve(process.argv[2]||path.join(root,'../build',version,'site/dist'));
await mkdir(out,{recursive:true});await cp(path.join(root,'src'),out,{recursive:true});
// Generated pages remain outside tracked source and inside the versioned build.
const pages=JSON.parse(await readFile(path.join(root,'content.json'),'utf8'));
const esc=s=>s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
function wrap(text,width){return text.split('\n').map(line=>{let result='',column=0;for(const word of line.split(' ')){if(column&&column+word.length+1>width){result+='\n';column=0;}if(column){result+=' ';column++;}result+=word;column+=word.length;}return result;}).join('\n');}
for(const width of [40,80]){
 const base=path.join(out,'lite',String(width));await mkdir(base,{recursive:true});
 for(const [slug,page] of Object.entries(pages)){
  const links=page.links.map(([label,href])=>[label,href.startsWith('/')||href.startsWith('https:')?href:href+'.html']);
  const plain=[page.title.toUpperCase(),'',...page.paragraphs.flatMap(p=>[wrap(p,width),'']),...links.map(([label,href],i)=>'['+(i+1)+'] '+label), '', 'Crowbar\'s Apple II Workshop'].join('\n');
  const html='<!doctype html><html lang="en"><head><meta charset="us-ascii"><meta name="viewport" content="width=device-width,initial-scale=1"><title>'+esc(page.title)+'</title></head><body><h1>'+esc(page.title)+'</h1>'+page.paragraphs.map(p=>'<p>'+esc(wrap(p,width)).replaceAll('\n','<br>')+'</p>').join('\n')+'<ul>'+links.map(([label,href])=>'<li><a href="'+esc(href)+'">'+esc(label)+'</a></li>').join('\n')+'</ul><p><a href="'+slug+'.txt">Plain text</a> | <a href="index.html">Text home</a> | <a href="/">Visual site</a></p><p>Colors are set by your physical display. No CSS or scripts required.</p></body></html>';
  await writeFile(path.join(base,slug+'.html'),html,'ascii');await writeFile(path.join(base,slug+'.txt'),plain,'ascii');
 }
}
// Default /lite mirrors 40-column files, without redirects or script negotiation.
for(const f of await readdir(path.join(out,'lite','40')))await cp(path.join(out,'lite','40',f),path.join(out,'lite',f));
const assets=path.join(out,'assets');await mkdir(assets,{recursive:true});
const files=[];
function row(y){return (y&7)*1024+((y>>3)&7)*128+(y>>6)*40;}
function picture(x,y,w,h){const nx=x/w,ny=y/h;return (ny>.86&&ny<.9)||[.22,.5,.78].some(c=>(ny>.16&&ny<.73&&Math.abs(nx-c)<(ny-.16)*.19)||(Math.abs(nx-c)<.016&&ny>.55&&ny<.84));}
async function asset(name,data,format){await writeFile(path.join(assets,name),data);files.push({file:'/assets/'+name,bytes:data.length,format});}
for(const color of [false,true]){
 const b=Buffer.alloc(1024);
 for(let y=0;y<48;y++)for(let x=0;x<40;x++){const r=y>>1,offset=(r&7)*128+(r>>3)*40+x;const c=picture(x,y,40,48)?(color?(y>40?13:12):15):0;b[offset]|=c<<((y&1)*4);}
 await asset('lores-'+(color?'color':'mono')+'.bin',b,'Raw 1KB page; load $0400; preserve screen-hole bytes in a loader.');
}
for(const [name,w,banks] of [['hires',280,1],['dhgr',560,2]]){
 const b=Buffer.alloc(8192*banks);
 for(let y=0;y<192;y++)for(let x=0;x<w;x++)if(picture(x,y,w,192)){
  const group=Math.floor(x/7),bank=banks===1?0:group%2,byte=banks===1?group:Math.floor(group/2);
  b[bank*8192+row(y)+byte]|=1<<(x%7);
 }
 await asset(name+'-mono.bin',b,banks===1?'Raw 8KB HGR page at $2000; bit 7 clear.':'Raw 16KB DHGR: AUX $2000-$3FFF first, MAIN $2000-$3FFF second; bit 7 clear.');
}
// A2TS, the loader that shows these screens, is assembled by build.ps1 before the portal is built.
const loader=await readFile(path.join(root,'../build',version,'A2TS-LOADER.BIN')).catch(()=>null);
if(!loader)throw new Error('A2TS-LOADER.BIN is not in build/'+version+': run build.ps1, which assembles it before building the portal.');
await asset('a2ts.bin',loader,'A2TS, the ProDOS loader for the screens above. Type BIN, address $6000. Keep it as A2TS beside LORES.COLOR, LORES.MONO, HIRES.MONO and DHGR.MONO, then BRUN A2TS.');
const manifest={schema:1,hardwareValidated:false,text:{defaultColumns:40,availableColumns:[40,80],requiresJavaScript:false},outputs:['composite','rgb','mono'],themes:['parchment','green','amber','contrast'],profiles:[{id:'lores',width:40,height:48,colors:16},{id:'hires',width:280,height:192,nativeFallback:'monochrome',note:'Hardware has constrained artifact colors; supplied pack uses bitmapped contrast.'},{id:'dhgr',width:560,height:192,nativeFallback:'monochrome',colorModeWidth:140,requires:'Compatible DHGR hardware and auxiliary memory'}],files};
await writeFile(path.join(assets,'profiles.json'),JSON.stringify(manifest,null,2)+'\n');
await writeFile(path.join(out,'_headers'),'/*\n  X-Content-Type-Options: nosniff\n  Referrer-Policy: strict-origin-when-cross-origin\n  X-Frame-Options: SAMEORIGIN\n');
console.log('Built portal: '+out);
