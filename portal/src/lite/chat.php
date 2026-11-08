<?php
// The Wire for a text browser: an Apple II reading through Farglade, or anything
// else without scripts. Plain ASCII, no styles, no cookies. A name is given once
// and carried in the address; a line is said with a one-field GET form, which is
// the only kind Farglade's browser fills in. The form carries a ticket made by
// this page for this visitor, and the room drops a line repeated within a
// minute, so a page loaded twice says its line once.
//
//   chat.php                       the talk, and a form for a name
//   chat.php?nick=NAME             the talk, and a form to say a line
//   chat.php?nick=NAME&k=TICKET&say=WORDS   say it, then the talk

define('WIRE', 1);
require __DIR__ . '/../chat/wire.php';

header('Content-Type: text/html; charset=us-ascii');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

function h($text)
{
    return htmlspecialchars($text, ENT_QUOTES, 'ISO-8859-1');
}

$now = time();
$asked = isset($_GET['nick']) && is_string($_GET['nick']) ? trim($_GET['nick']) : '';
$nick = wire_nick($asked);
$say = wire_text(isset($_GET['say']) ? $_GET['say'] : '');
$ticket = isset($_GET['k']) ? $_GET['k'] : '';
$note = '';
if ($asked !== '' && $nick === '') {
    $note = 'That name will not do. Use 1 to ' . WIRE_NICK . ' letters, digits, - or _, starting with a letter.';
}

$room = wire_with(function (&$room) use ($nick, $say, $ticket, $now, &$note) {
    $changed = wire_seen($room, $nick, $now);
    if ($nick !== '' && $say !== '') {
        if (!wire_ticket_ok($room, $nick, $ticket, $now)) {
            $note = 'That line was not said: this page had grown old, or was made for someone else. Say it again from here.';
        } else {
            $said = wire_say($room, $nick, $say, 'say', $now);
            if ($said[0]) {
                $changed = true;
            } else {
                $note = 'Not said: ' . $said[1];
            }
        }
    }
    return array($room, $changed);
});

$self = 'chat.php';
$again = $nick === '' ? $self : $self . '?nick=' . rawurlencode($nick);
echo '<!doctype html><html lang="en"><head><meta charset="us-ascii">';
echo '<meta name="viewport" content="width=device-width,initial-scale=1"><title>The Wire</title></head><body>';
echo '<h1>The Wire</h1>';
if ($room === null) {
    echo '<p>The room cannot be opened on this host just now.</p>';
} else {
    $lines = wire_after($room, 0, 15);
    echo '<p>The workshop\'s own room, kept on this site. ';
    echo $nick === '' ? 'You are reading.' : 'You are ' . h($nick) . '.';
    echo '</p>';
    if ($note !== '') {
        echo '<p>! ' . h($note) . '</p>';
    }
    echo '<pre>';
    if (!$lines) {
        echo "(nobody has spoken yet)\n";
    }
    foreach ($lines as $line) {
        echo h($line['k'] === 'act' ? '* ' . $line['n'] . ' ' . $line['x'] : '<' . $line['n'] . '> ' . $line['x']) . "\n";
    }
    echo '</pre>';
    $here = wire_here($room, $now);
    echo '<p>Here now: ' . ($here ? h(implode(', ', $here)) : 'nobody') . '.</p>';
    echo '<form method="get" action="' . $self . '">';
    if ($nick === '') {
        echo '<input type="text" name="nick" title="your name" maxlength="' . WIRE_NICK . '">';
        echo '<input type="submit" value="Take this name">';
    } else {
        echo '<input type="hidden" name="nick" value="' . h($nick) . '">';
        echo '<input type="hidden" name="k" value="' . h(wire_ticket($room, $nick, $now)) . '">';
        echo '<input type="text" name="say" title="say" maxlength="' . WIRE_TEXT . '">';
        echo '<input type="submit" value="Say">';
    }
    echo '</form>';
}
echo '<ul><li><a href="' . h($again) . '">Look again</a></li>';
if ($nick !== '') {
    echo '<li><a href="' . $self . '">Change your name</a></li>';
}
echo '<li><a href="irc.html">How the Wire works</a></li>';
echo '<li><a href="index.html">Text home</a></li></ul>';
echo '<p>Short plain messages. Be kind. No flooding, no personal details.</p>';
echo '</body></html>';
