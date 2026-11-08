<?php
// The guestbook for a text browser: an Apple II reading through Farglade, or
// anything else without scripts. Plain ASCII, no styles, no cookies. A name is
// given first and carried in the address; the note is then written with a
// one-field GET form, which is the only kind Farglade's browser fills in. The
// form carries a ticket made by this page for this visitor, and the book takes
// the same note from the same name once, so a page loaded twice signs once.
//
//   guestbook.php                          the newest notes, and a form for a name
//   guestbook.php?before=ID                the notes before number ID
//   guestbook.php?name=NAME                a form to write a note as NAME
//   guestbook.php?name=NAME&k=TICKET&words=WORDS   write it, then the newest notes

define('BOOK', 1);
require __DIR__ . '/../guestbook/book.php';

header('Content-Type: text/html; charset=us-ascii');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

function h($text)
{
    return htmlspecialchars($text, ENT_QUOTES, 'ISO-8859-1');
}

const LITE_PAGE = 10;           // notes to a page here: small screens, slow lines

$now = time();
$asked = isset($_GET['name']) && is_string($_GET['name']) ? trim($_GET['name']) : '';
$name = book_name($asked);
$words = book_text(isset($_GET['words']) ? $_GET['words'] : '');
$ticket = isset($_GET['k']) ? $_GET['k'] : '';
$before = isset($_GET['before']) ? max(0, (int) $_GET['before']) : 0;
$note = '';
$signed = false;
if ($asked !== '' && $name === '') {
    $note = 'That name will not do. Use 1 to ' . BOOK_NAME . ' letters, digits, spaces or - _ . \', starting with a letter or digit.';
}

$book = book_with(function (&$book) use ($name, $words, $ticket, $now, &$note, &$signed) {
    $changed = false;
    if ($name !== '' && $words !== '') {
        if (!book_ticket_ok($book, $name, $ticket, $now)) {
            $note = 'That note was not written: this page had grown old, or was made for someone else. Write it again from here.';
        } else {
            $result = book_sign($book, $name, $words, 'text', $now);
            if ($result[0]) {
                $changed = true;
                $signed = true;
                $note = 'Thank you, ' . $name . '. Your note is in the book.';
            } else {
                $note = 'Not written: ' . $result[1];
            }
        }
    }
    return array($book, $changed);
});

$self = 'guestbook.php';
echo '<!doctype html><html lang="en"><head><meta charset="us-ascii">';
echo '<meta name="viewport" content="width=device-width,initial-scale=1"><title>The Guestbook</title></head><body>';
echo '<h1>The Guestbook</h1>';
if ($book === null) {
    echo '<p>The book cannot be opened on this host just now.</p>';
} else {
    $writing = $name !== '' && !$signed;
    echo '<p>A book for passing travelers, kept on this site. ';
    echo $writing ? 'You are signing as ' . h($name) . '.' : 'Leave a note, even when the workshop is quiet.';
    echo '</p>';
    if ($note !== '') {
        echo '<p>! ' . h($note) . '</p>';
    }
    echo '<form method="get" action="' . $self . '">';
    if ($writing) {
        echo '<input type="hidden" name="name" value="' . h($name) . '">';
        echo '<input type="hidden" name="k" value="' . h(book_ticket($book, $name, $now)) . '">';
        echo '<input type="text" name="words" title="your note" maxlength="' . BOOK_TEXT . '">';
        echo '<input type="submit" value="Write it in the book">';
    } else {
        echo '<input type="text" name="name" title="your name" maxlength="' . BOOK_NAME . '">';
        echo '<input type="submit" value="Sign the book">';
    }
    echo '</form>';
    $page = book_page($book, $before, LITE_PAGE);
    if (!$page[0]) {
        echo '<p>' . ($before ? '(no older notes)' : '(nobody has signed yet)') . '</p>';
    }
    foreach ($page[0] as $entry) {
        echo '<p>' . h(book_date($entry['t']) . ' ' . $entry['n'] . ($entry['v'] === 'text' ? ' (text edition)' : ''))
            . '<br>' . h($entry['x']) . "</p>\n";
    }
    echo '<p>' . count($book['entries']) . (count($book['entries']) === 1 ? ' note' : ' notes') . ' in the book.</p>';
}
echo '<ul>';
if ($book !== null && $page[1]) {
    $last = end($page[0]);
    echo '<li><a href="' . $self . '?before=' . (int) $last['i'] . '">Older notes</a></li>';
}
echo '<li><a href="' . $self . '">Newest notes</a></li>';
echo '<li><a href="chat.php">The Wire: chat room</a></li>';
echo '<li><a href="index.html">Text home</a></li></ul>';
echo '<p>Short plain notes, up to ' . BOOK_TEXT . ' letters. Be kind. No web addresses, no personal details.</p>';
echo '</body></html>';
