// The guestbook in a browser. The book is this site's own (guestbook/api.php): the page asks
// it for its notes and tells it what to write. Nothing is loaded from, or sent to, any other
// host. Notes are shown as text, never as markup.
const API = '/guestbook/api.php';
const NAME = /^[A-Za-z0-9][A-Za-z0-9 _.'-]{0,23}$/;
const el = id => document.getElementById(id);
const status = el('status'), sign = el('sign'), nameBox = el('name'), textBox = el('text');
const list = el('entries'), count = el('count'), older = el('older');
let oldest = 0, busy = false;

try {
  const saved = localStorage.getItem('workshop-guestbook-name');
  if (saved && NAME.test(saved)) nameBox.value = saved;
} catch {}

function day(seconds) {
  return new Date(seconds * 1000).toISOString().slice(0, 10);
}

function entry(note) {
  const row = document.createElement('div'), head = document.createElement('p'), words = document.createElement('p');
  row.className = 'book-entry';
  head.className = 'book-head';
  head.textContent = day(note.t) + ' / ' + note.n + (note.v === 'text' ? ' / text edition' : '');
  words.className = 'book-words';
  words.textContent = note.x;
  row.append(head, words);
  return row;
}

async function ask(query, form) {
  const options = form
    ? {method: 'POST', headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: new URLSearchParams(form).toString(), cache: 'no-store'}
    : {cache: 'no-store'};
  const answer = await (await fetch(API + query, options)).json();
  if (!answer || typeof answer.ok !== 'boolean') throw new Error('not the book');
  return answer;
}

// Read a page of the book: the newest notes, or the ones before the oldest already shown.
async function read(more) {
  try {
    const answer = await ask('?op=read' + (more && oldest ? '&before=' + oldest : ''));
    if (!answer.ok) throw new Error(answer.why);
    if (!more) list.replaceChildren();
    for (const note of answer.entries) {
      list.append(entry(note));
      oldest = note.i;
    }
    if (!more && !answer.entries.length) oldest = 0;
    count.textContent = answer.count ? answer.count + (answer.count === 1 ? ' note in the book.' : ' notes in the book.') : 'Nobody has signed yet. Be the first.';
    older.hidden = !answer.more;
    return true;
  } catch {
    status.textContent = 'The book is not answering just now. Try again in a moment.';
    return false;
  }
}

sign.addEventListener('submit', async event => {
  event.preventDefault();
  if (busy) return;
  const name = nameBox.value.trim().replace(/ {2,}/g, ' '), text = textBox.value.trim();
  if (!NAME.test(name)) {
    status.textContent = 'A name is 1 to 24 letters, digits, spaces or - _ . \', starting with a letter or digit.';
    return;
  }
  if (!text) {
    status.textContent = 'Write a few words first.';
    return;
  }
  busy = true;
  try {
    const answer = await ask('', {op: 'sign', name, text});
    if (!answer.ok) {
      status.textContent = 'Not written: ' + answer.why;
      return;
    }
    try { localStorage.setItem('workshop-guestbook-name', name); } catch {}
    textBox.value = '';
    if (await read(false)) status.textContent = 'Thank you, ' + name + '. Your note is in the book.';
  } catch {
    status.textContent = 'That was not written: the book is not answering.';
  } finally {
    busy = false;
  }
});

older.addEventListener('click', () => { read(true); });

read(false);
