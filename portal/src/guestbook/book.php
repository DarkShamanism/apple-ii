<?php
// The guestbook: a book kept on this site for visitors to sign.
//
// One book, one file. Like the Wire it needs no outside service, no account,
// no password and no cookie. Two doors lead to it:
//   guestbook/api.php    JSON, for the browser page
//   lite/guestbook.php   a page with no scripts, for an Apple II's text browser
// This file is the book itself: where it is kept, and the rules it keeps.
// It is written for PHP 7.0 and later. Asked for by name it says nothing.
//
// The book is kept in guestbook/data/entries.php: a first line that stops PHP
// showing the rest, a second line of the book's own notes, then one entry to a
// line. Whoever runs the site takes an entry out by deleting its line on the
// host, and empties the book by deleting the file; it is made again, blank,
// the next time anyone asks. There is no keeper's door on the web.

if (!defined('BOOK')) {
    http_response_code(404);
    exit;
}

const BOOK_PROTOCOL = 'workshop-guestbook/1';
const BOOK_KEPT = 500;          // entries kept; older ones are let go
const BOOK_TEXT = 300;          // letters to an entry
const BOOK_NAME = 24;           // letters to a name
const BOOK_PAGE = 20;           // entries shown at a time
const BOOK_REST = 120;          // seconds one visitor waits between entries
const BOOK_DAY = 5;             // entries one visitor may leave in a day
const BOOK_HOUR = 20;           // entries the whole book takes in an hour
const BOOK_GUARD = "<?php http_response_code(404); exit; ?>\n";

function book_dir()
{
    return __DIR__ . '/data';
}

// The book's file, opened and made ready. Null when the host will not let it be kept.
function book_open()
{
    $dir = book_dir();
    if (!is_dir($dir) && !@mkdir($dir, 0755, true)) {
        return null;
    }
    if (!is_file($dir . '/.htaccess')) {
        @file_put_contents($dir . '/.htaccess',
            "<IfModule mod_authz_core.c>\nRequire all denied\n</IfModule>\n<IfModule !mod_authz_core.c>\nDeny from all\n</IfModule>\n");
    }
    $handle = @fopen($dir . '/entries.php', 'c+');
    return $handle ? $handle : null;
}

function book_blank()
{
    return array('v' => 1, 'salt' => bin2hex(random_bytes(16)), 'next' => 1, 'hits' => array(), 'entries' => array());
}

// What is in the file. A line that is not an entry (one the owner half removed,
// say) is passed over rather than spoiling the book. $fresh is set when there
// was no book to read and a blank one was begun.
function book_load($handle, &$fresh)
{
    rewind($handle);
    $lines = explode("\n", (string) stream_get_contents($handle));
    $notes = isset($lines[1]) ? json_decode($lines[1], true) : null;
    $fresh = !is_array($notes) || !isset($notes['salt'], $notes['next']) || !is_string($notes['salt']);
    if ($fresh) {
        return book_blank();
    }
    $book = array('v' => 1, 'salt' => $notes['salt'], 'next' => max(1, (int) $notes['next']),
                  'hits' => isset($notes['hits']) && is_array($notes['hits']) ? $notes['hits'] : array(), 'entries' => array());
    for ($i = 2; $i < count($lines); ++$i) {
        $entry = json_decode($lines[$i], true);
        if (is_array($entry) && isset($entry['i'], $entry['t'], $entry['n'], $entry['x'])
            && is_string($entry['n']) && is_string($entry['x'])) {
            $book['entries'][] = array('i' => (int) $entry['i'], 't' => (int) $entry['t'], 'n' => $entry['n'], 'x' => $entry['x'],
                                       'v' => isset($entry['v']) && $entry['v'] === 'text' ? 'text' : 'web');
            $book['next'] = max($book['next'], (int) $entry['i'] + 1);      // a number is never given out twice
        }
    }
    return $book;
}

function book_save($handle, $book)
{
    $out = BOOK_GUARD . json_encode(array('v' => 1, 'salt' => $book['salt'], 'next' => $book['next'], 'hits' => $book['hits'])) . "\n";
    foreach ($book['entries'] as $entry) {
        $out .= json_encode($entry) . "\n";
    }
    rewind($handle);
    ftruncate($handle, 0);
    fwrite($handle, $out);
    fflush($handle);
}

// Run $work on the book with the file locked; keep what it changed when it says so.
// $work is given the book by reference and returns array(answer, changed).
function book_with($work)
{
    $handle = book_open();
    if (!$handle) {
        return null;
    }
    if (!flock($handle, LOCK_EX)) {
        fclose($handle);
        return null;
    }
    $fresh = false;
    $book = book_load($handle, $fresh);
    $result = $work($book);
    if ($result[1] || $fresh) {         // a book just begun is kept at once: its tickets are made from what it holds
        book_save($handle, $book);
    }
    flock($handle, LOCK_UN);
    fclose($handle);
    return $result[0];
}

// Words as the book keeps them: plain ASCII an Apple II can show, on one line.
function book_plain($value, $most)
{
    $value = is_string($value) ? $value : '';
    $value = preg_replace('/[\x00-\x1F\x7F]+/', ' ', $value);
    $value = preg_replace('/[^\x20-\x7E]/', '?', $value);
    $value = trim(preg_replace('/ {2,}/', ' ', $value));
    return substr($value, 0, $most);
}

// A name as the book takes it, or '' when it will not do.
function book_name($value)
{
    $value = is_string($value) ? trim(preg_replace('/ {2,}/', ' ', $value)) : '';
    return preg_match('/^[A-Za-z0-9][A-Za-z0-9 _.\'-]{0,' . (BOOK_NAME - 1) . '}$/', $value) ? rtrim($value) : '';
}

function book_text($value)
{
    return book_plain($value, BOOK_TEXT);
}

// A book is for notes, not for notices: anything that reads as a web address is refused.
function book_has_address($text)
{
    return (bool) preg_match('/https?:|www\.|:\/\//i', $text);
}

// Who is asking, as far as the book needs to know: enough to count their entries, no more.
function book_who($book)
{
    $address = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';
    return substr(hash('sha256', $book['salt'] . '|' . $address), 0, 16);
}

// Sign the book. Returns array(id, '') or array(0, why not).
function book_sign(&$book, $name, $text, $via, $now)
{
    if ($name === '') {
        return array(0, 'a name is one to ' . BOOK_NAME . ' letters, digits, spaces or - _ . \', starting with a letter or digit.');
    }
    if ($text === '') {
        return array(0, 'nothing was written.');
    }
    if (book_has_address($name) || book_has_address($text)) {
        return array(0, 'the book takes notes, not web addresses.');
    }
    foreach ($book['entries'] as $entry) {
        if ($now - $entry['t'] < 600 && $entry['n'] === $name && $entry['x'] === $text) {
            return array($entry['i'], '');      // the same note again within ten minutes: a page loaded twice
        }
    }
    $who = book_who($book);
    $mine = array();
    foreach (isset($book['hits'][$who]) && is_array($book['hits'][$who]) ? $book['hits'][$who] : array() as $when) {
        if ($now - $when < 86400) {
            $mine[] = (int) $when;
        }
    }
    if ($mine && $now - end($mine) < BOOK_REST) {
        return array(0, 'wait a little: the book takes one note from a visitor every ' . (int) (BOOK_REST / 60) . ' minutes.');
    }
    if (count($mine) >= BOOK_DAY) {
        return array(0, 'wait a little: the book takes ' . BOOK_DAY . ' notes a day from one visitor.');
    }
    $hour = 0;
    foreach ($book['entries'] as $entry) {
        if ($now - $entry['t'] < 3600) {
            ++$hour;
        }
    }
    if ($hour >= BOOK_HOUR) {
        return array(0, 'the book is busy just now. try again in an hour.');
    }
    $id = (int) $book['next'];
    $book['next'] = $id + 1;
    $book['entries'][] = array('i' => $id, 't' => $now, 'n' => $name, 'x' => $text, 'v' => $via === 'text' ? 'text' : 'web');
    if (count($book['entries']) > BOOK_KEPT) {
        $book['entries'] = array_slice($book['entries'], -BOOK_KEPT);
    }
    $mine[] = $now;
    $book['hits'][$who] = $mine;
    foreach ($book['hits'] as $visitor => $times) {
        if (!is_array($times) || !$times || $now - end($times) > 86400) {
            unset($book['hits'][$visitor]);
        }
    }
    return array($id, '');
}

// A page of the book, newest first: the entries before number $before (the
// newest of all when it is 0), at most $most of them, and whether older ones remain.
function book_page($book, $before, $most)
{
    $found = array();
    for ($i = count($book['entries']) - 1; $i >= 0; --$i) {
        if ($before <= 0 || $book['entries'][$i]['i'] < $before) {
            $found[] = $book['entries'][$i];
        }
    }
    return array(array_slice($found, 0, $most), count($found) > $most);
}

function book_date($when)
{
    return gmdate('Y-m-d', (int) $when);
}

// A ticket the script-free page puts in its form, so that the book can only be
// signed from a page this site made, for this visitor, in the last hour or so.
function book_ticket($book, $name, $now)
{
    return substr(hash('sha256', $book['salt'] . '|ticket|' . $name . '|' . book_who($book) . '|' . (int) floor($now / 3600)), 0, 12);
}

function book_ticket_ok($book, $name, $ticket, $now)
{
    return is_string($ticket) && (hash_equals(book_ticket($book, $name, $now), $ticket)
                                  || hash_equals(book_ticket($book, $name, $now - 3600), $ticket));
}
