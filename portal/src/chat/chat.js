// The Wire in a browser. The room is this site's own (chat/api.php): the page asks it what
// has been said every few seconds and tells it what to say. Nothing is loaded from, or sent
// to, any other host. Lines are shown as text, never as markup.
const API = '/chat/api.php';
const NICK = /^[A-Za-z][A-Za-z0-9_-]{0,15}$/;
const el = id => document.getElementById(id);
const status = el('status'), join = el('join'), nickBox = el('nick'), room = el('room');
const log = el('log'), talk = el('talk'), sayBox = el('say'), here = el('here'), leave = el('leave');
let nick = '', last = 0, timer = null, misses = 0, open = false;

try {
  const saved = localStorage.getItem('workshop-wire-nick');
  if (saved && NICK.test(saved)) nickBox.value = saved;
} catch {}

function line(text, kind) {
  const row = document.createElement('div');
  row.className = kind ? 'chat-line ' + kind : 'chat-line';
  row.textContent = text;
  log.append(row);
  log.scrollTop = log.scrollHeight;
}

function clock(seconds) {
  const when = new Date(seconds * 1000);
  return String(when.getHours()).padStart(2, '0') + ':' + String(when.getMinutes()).padStart(2, '0');
}

function show(entry) {
  const words = entry.k === 'act' ? '* ' + entry.n + ' ' + entry.x : '<' + entry.n + '> ' + entry.x;
  line('[' + clock(entry.t) + '] ' + words, entry.n === nick ? 'mine' : '');
}

async function ask(query, form) {
  const options = form
    ? {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: new URLSearchParams(form).toString(), cache: 'no-store'}
    : {cache: 'no-store'};
  const answer = await (await fetch(API + query, options)).json();
  if (!answer || typeof answer.ok !== 'boolean') throw new Error('not the wire');
  return answer;
}

async function poll() {
  timer = null;
  if (!open) return;
  try {
    const answer = await ask('?op=read&since=' + last + '&nick=' + encodeURIComponent(nick));
    if (!open) return;
    if (answer.last < last) last = answer.last;         // the room was started afresh
    for (const entry of answer.lines) {
      if (entry.i > last) {
        last = entry.i;
        show(entry);
      }
    }
    here.textContent = answer.here.length ? answer.here.join(', ') : 'nobody';
    if (misses) status.textContent = 'Back in the room as ' + nick + '.';
    misses = 0;
  } catch {
    misses += 1;
    status.textContent = 'The room is not answering. Trying again.';
  }
  if (open) timer = setTimeout(poll, document.hidden ? 15000 : misses ? Math.min(30000, 3000 * misses) : 3000);
}

function enter(name) {
  nick = name;
  try { localStorage.setItem('workshop-wire-nick', nick); } catch {}
  open = true;
  last = 0;
  misses = 0;
  log.replaceChildren();
  join.hidden = true;
  room.hidden = false;
  status.textContent = 'You are in the room as ' + nick + '.';
  if (timer) clearTimeout(timer);
  poll();
  sayBox.focus();
}

async function say(text, kind) {
  try {
    const answer = await ask('', kind ? {op: 'say', nick, text, kind} : {op: 'say', nick, text});
    if (!answer.ok) {
      line('! ' + answer.why, 'note');
      return;
    }
    if (timer) clearTimeout(timer);
    poll();
  } catch {
    line('! that was not said: the room is not answering.', 'note');
  }
}

join.addEventListener('submit', event => {
  event.preventDefault();
  const name = nickBox.value.trim();
  if (!NICK.test(name)) {
    status.textContent = 'A name is 1 to 16 letters, digits, - or _, starting with a letter.';
    return;
  }
  enter(name);
});

talk.addEventListener('submit', event => {
  event.preventDefault();
  const text = sayBox.value.trim();
  sayBox.value = '';
  if (!text || !open) return;
  const verb = text.split(' ')[0].toLowerCase(), rest = text.slice(verb.length).trim();
  if (verb === '/me') {
    if (rest) say(rest, 'act');
  } else if (verb === '/nick') {
    if (NICK.test(rest)) {
      nick = rest;
      try { localStorage.setItem('workshop-wire-nick', nick); } catch {}
      status.textContent = 'You are in the room as ' + nick + '.';
    } else {
      line('! a name is 1 to 16 letters, digits, - or _, starting with a letter.', 'note');
    }
  } else if (verb === '/names') {
    line('* here now: ' + here.textContent, 'note');
  } else if (verb === '/help') {
    line('* /me <does something>   /nick <name>   /names   anything else is said to the room.', 'note');
  } else if (verb.startsWith('/')) {
    line('! the room does not know ' + verb + '. /help lists what it does.', 'note');
  } else {
    say(text, '');
  }
});

leave.addEventListener('click', () => {
  open = false;
  if (timer) clearTimeout(timer);
  timer = null;
  room.hidden = true;
  join.hidden = false;
  status.textContent = 'You left the room. Choose a name to join again.';
});
