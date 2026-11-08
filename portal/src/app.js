const allowed = {output:['composite','rgb','mono'],mode:['lores','hires','dhgr'],theme:['parchment','green','amber','contrast'],columns:['40','80']};
const defaults = {output:'composite',mode:'lores',theme:'parchment',columns:'40'};
let saved = {};
try { saved = JSON.parse(localStorage.getItem('workshop-display-v1')) || {}; } catch {}
const settings = Object.fromEntries(Object.entries(defaults).map(([key,value])=>[key,allowed[key].includes(saved[key])?saved[key]:value]));
document.documentElement.dataset.theme = settings.theme;
const controls = Object.keys(defaults).map(key=>document.getElementById(key));
function redraw(){
  document.documentElement.dataset.theme=settings.theme;
  const canvas=document.getElementById('preview'); if(!canvas)return;
  const mono=settings.output==='mono'||settings.mode!=='lores'||settings.theme==='contrast';
  const w=settings.mode==='lores'?40:settings.mode==='hires'?280:560, h=settings.mode==='lores'?48:192;
  canvas.width=w;canvas.height=h;
  const ctx=canvas.getContext('2d');
  const foreground=settings.theme==='amber'?'#edbc62':settings.theme==='green'?'#b4cc8c':'#f2f0cf';
  ctx.fillStyle='#10180d';ctx.fillRect(0,0,w,h);
  for(let y=0;y<h;y++)for(let x=0;x<w;x++){
    const nx=x/w,ny=y/h;
    const tree=[.22,.5,.78].some(c=>ny>.16&&ny<.73&&Math.abs(nx-c)<(ny-.16)*.19)||([.22,.5,.78].some(c=>Math.abs(nx-c)<.016)&&ny>.55&&ny<.84);
    const ground=ny>.86&&ny<.9;
    if(tree||ground){ctx.fillStyle=mono?foreground:(ground?'#b8902e':settings.output==='rgb'?'#43aa3a':'#748c47');ctx.fillRect(x,y,1,1);}
  }
  document.getElementById('profile-label').textContent=settings.mode.toUpperCase()+' / '+settings.output.toUpperCase();
  document.getElementById('dimensions').textContent=w+' × '+h+(settings.mode==='lores'?' / 16-color mode':' / monochrome fallback');
  document.getElementById('profile-note').textContent=settings.mode==='dhgr'?'Requires compatible double hi-res hardware and auxiliary memory. Preview is illustrative.':settings.output==='rgb'?'RGB card palettes and modes vary. Select the matching mode on your hardware.':settings.output==='mono'?'The physical monitor determines phosphor color; website tints are previews only.':'Composite colors depend on monitor and signal. This is not an artifact-color emulator.';
  const a=document.getElementById('text-profile');a.href='/lite/'+settings.columns+'/';a.textContent='Open '+settings.columns+'-column edition ↗';
  document.getElementById('native-download').href='/assets/'+(settings.mode==='lores'?'lores-'+(mono?'mono':'color'):settings.mode+'-mono')+'.bin';
}
for(const [index,key] of Object.keys(defaults).entries()){
  const control=controls[index];if(!control)continue;control.value=settings[key];
  control.addEventListener('change',()=>{settings[key]=control.value;try{localStorage.setItem('workshop-display-v1',JSON.stringify(settings));}catch{}redraw();});
}
document.getElementById('reset')?.addEventListener('click',()=>{Object.assign(settings,defaults);try{localStorage.removeItem('workshop-display-v1');}catch{}controls.forEach((c,i)=>{if(c)c.value=settings[Object.keys(defaults)[i]];});redraw();});
redraw();
fetch('/config.json').then(r=>{if(!r.ok)throw Error();return r.json();}).then(c=>{if(c.chat.enabled&&document.getElementById('wire-state'))document.getElementById('wire-state').textContent='The room is kept on this site. Browser and Apple II visitors share it. Open The Wire to join.';}).catch(()=>{});
