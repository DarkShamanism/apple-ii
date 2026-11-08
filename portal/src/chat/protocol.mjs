export function parseLine(line) {
  let rest=line.trim(),tags='',prefix='';
  if(rest.startsWith('@')){const i=rest.indexOf(' ');if(i<0)return null;tags=rest.slice(1,i);rest=rest.slice(i+1);}
  if(rest.startsWith(':')){const i=rest.indexOf(' ');if(i<0)return null;prefix=rest.slice(1,i);rest=rest.slice(i+1);}
  const i=rest.indexOf(' :'),head=i<0?rest:rest.slice(0,i);
  const parts=head.split(/ +/),command=parts.shift()?.toUpperCase();
  if(!command)return null;
  return {tags,prefix,command,params:i<0?parts:[...parts,rest.slice(i+2)]};
}
export function validNick(nick){return /^[A-Za-z][A-Za-z0-9_-]{0,23}$/.test(nick);}
export function safeMessage(value){return value.replace(/[\x00-\x1f\x7f]/g,' ').trim().slice(0,300);}
export function visibleText(value){return value.replace(/\x03(?:\d{1,2}(?:,\d{1,2})?)?/g,'').replace(/[\x00-\x1f\x7f]/g,'');}
