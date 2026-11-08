<?php
// The Wire: the workshop's own chat room, kept on this site.
//
// One room, one file. There is no IRC server here and no outside service: a
// shared web host cannot run one, and does not need to. Every client asks this
// site what has been said and tells it what to say:
//   chat/api.php    JSON, for the browser page and for Farglade's wire program
//   lite/chat.php   a page with no scripts, for an Apple II's text browser
// This file is the room itself: where it is kept, and the rules it keeps.
// It is written for PHP 7.0 and later. Asked for by name it says nothing.
//
// The room has no keeper's door on the web. Whoever runs the site empties the
// room by deleting chat/data/room.php on the host; it is made again, blank,
// the next time anyone asks.

if (!defined('WIRE')) {
    http_response_code(404);
    exit;
}

const WIRE_PROTOCOL = 'workshop-chat/1';
const WIRE_ROOM = 'workshop';
const WIRE_LINES = 300;         // lines kept; older ones are let go
const WIRE_TEXT = 200;          // letters to a line
const WIRE_NICK = 16;           // letters to a name
const WIRE_HERE = 120;          // seconds a name stays on the list after it last asked
const WIRE_BURST = 6;           // lines one visitor may say in WIRE_SPAN seconds
const WIRE_SPAN = 20;
const WIRE_FLOOD = 40;          // lines the whole room may hear in a minute
const WIRE_GUARD = "<?php http_response_code(404); exit; ?>\n";

function wire_dir()
{
    return __DIR__ . '/data';
}

// The room's file, opened and made ready. Null when the host will not let it be kept.
function wire_open()
{
    $dir = wire_dir();
    if (!is_dir($dir) && !@mkdir($dir, 0755, true)) {
        return null;
    }
    if (!is_file($dir . '/.htaccess')) {
        @file_put_contents($dir . '/.htaccess',
            "<IfModule mod_authz_core.c>\nRequire all denied\n</IfModule>\n<IfModule !mod_authz_core.c>\nDeny from all\n</IfModule>\n");
    }
    $handle = @fopen($dir . '/room.php', 'c+');
    return $handle ? $handle : null;
}

function wire_blank()
{
    return array('v' => 1, 'salt' => bin2hex(random_bytes(16)), 'next' => 1, 'lines' => array(),
                 'seen' => array(), 'hits' => array());
}

// What is in the file. The first line stops PHP from ever showing the rest.
function wire_load($handle)
{
    rewind($handle);
    $raw = stream_get_contents($handle);
    $at = strpos($raw, "\n");
    $room = $at === false ? null : json_decode(substr($raw, $at + 1), true);
    if (!is_array($room) || !isset($room['lines'], $room['next'], $room['salt'])) {
        return wire_blank();
    }
    foreach (array('seen', 'hits') as $part) {
        if (!isset($room[$part]) || !is_array($room[$part])) {
            $room[$part] = array();
        }
    }
    return $room;
}

function wire_save($handle, $room)
{
    rewind($handle);
    ftruncate($handle, 0);
    fwrite($handle, WIRE_GUARD . json_encode($room));
    fflush($handle);
}

// Run $work on the room with the file locked; keep what it changed when it says so.
// $work is given the room by reference and returns array(answer, changed).
function wire_with($work)
{
    $handle = wire_open();
    if (!$handle) {
        return null;
    }
    if (!flock($handle, LOCK_EX)) {
        fclose($handle);
        return null;
    }
    $room = wire_load($handle);
    $result = $work($room);
    if ($result[1]) {
        wire_save($handle, $room);
    }
    flock($handle, LOCK_UN);
    fclose($handle);
    return $result[0];
}

// A name as the room takes it, or '' when it will not do.
function wire_nick($value)
{
    $value = is_string($value) ? trim($value) : '';
    return preg_match('/^[A-Za-z][A-Za-z0-9_-]{0,' . (WIRE_NICK - 1) . '}$/', $value) ? $value : '';
}

// Words as the room keeps them: plain ASCII an Apple II can show, on one line.
function wire_text($value)
{
    $value = is_string($value) ? $value : '';
    $value = preg_replace('/[\x00-\x1F\x7F]+/', ' ', $value);
    $value = preg_replace('/[^\x20-\x7E]/', '?', $value);
    $value = trim(preg_replace('/ {2,}/', ' ', $value));
    return substr($value, 0, WIRE_TEXT);
}

// Who is asking, as far as the room needs to know: enough to count their lines, no more.
function wire_who($room)
{
    $address = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';
    return substr(hash('sha256', $room['salt'] . '|' . $address), 0, 16);
}

function wire_seen(&$room, $nick, $now)
{
    if ($nick === '') {
        return false;
    }
    $before = isset($room['seen'][$nick]) ? $room['seen'][$nick] : 0;
    if ($now - $before < 20) {
        return false;                   // noted recently enough: no need to write the file again
    }
    $room['seen'][$nick] = $now;
    foreach ($room['seen'] as $name => $when) {
        if ($now - $when > 3600) {
            unset($room['seen'][$name]);
        }
    }
    return true;
}

function wire_here($room, $now)
{
    $here = array();
    foreach ($room['seen'] as $name => $when) {
        if ($now - $when <= WIRE_HERE) {
            $here[] = (string) $name;
        }
    }
    sort($here, SORT_STRING | SORT_FLAG_CASE);
    return $here;
}

// Say a line. Returns array(id, '') or array(0, why not).
function wire_say(&$room, $nick, $text, $kind, $now)
{
    if ($nick === '') {
        return array(0, 'a name is one to ' . WIRE_NICK . ' letters, digits, - or _, starting with a letter.');
    }
    if ($text === '') {
        return array(0, 'nothing was said.');
    }
    $who = wire_who($room);
    $mine = isset($room['hits'][$who]) ? $room['hits'][$who] : array();
    $recent = array();
    foreach ($mine as $when) {
        if ($now - $when < WIRE_SPAN) {
            $recent[] = $when;
        }
    }
    if (count($recent) >= WIRE_BURST) {
        return array(0, 'slow down: the room takes ' . WIRE_BURST . ' lines in ' . WIRE_SPAN . ' seconds from one visitor.');
    }
    $minute = 0;
    for ($i = count($room['lines']) - 1; $i >= 0 && $now - $room['lines'][$i]['t'] < 60; --$i) {
        ++$minute;
    }
    if ($minute >= WIRE_FLOOD) {
        return array(0, 'the room is loud just now. try again in a minute.');
    }
    for ($i = count($room['lines']) - 1; $i >= 0 && $now - $room['lines'][$i]['t'] < 60; --$i) {
        $line = $room['lines'][$i];
        if ($line['n'] === $nick && $line['x'] === $text && $line['k'] === $kind) {
            return array($line['i'], '');       // the same line again within a minute: a page loaded twice
        }
    }
    $id = (int) $room['next'];
    $room['next'] = $id + 1;
    $room['lines'][] = array('i' => $id, 't' => $now, 'n' => $nick, 'k' => $kind, 'x' => $text);
    if (count($room['lines']) > WIRE_LINES) {
        $room['lines'] = array_slice($room['lines'], -WIRE_LINES);
    }
    $recent[] = $now;
    $room['hits'][$who] = $recent;
    foreach ($room['hits'] as $name => $times) {
        if (!$times || $now - end($times) > 600) {
            unset($room['hits'][$name]);
        }
    }
    $room['seen'][$nick] = $now;
    return array($id, '');
}

// The lines after $since, at most $most of them, oldest first.
function wire_after($room, $since, $most)
{
    $lines = array();
    foreach ($room['lines'] as $line) {
        if ($line['i'] > $since) {
            $lines[] = $line;
        }
    }
    return array_slice($lines, -$most);
}

// A ticket the script-free page puts in its form, so that a line can only be
// said from a page this site made, for this visitor, in the last hour or so.
// It is made from who is asking as well as the name: a ticket read off one
// visitor's page is no use in a link handed to another, so nobody can be made
// to speak, or to spend their own six lines, by following an address.
function wire_ticket($room, $nick, $now)
{
    return substr(hash('sha256', $room['salt'] . '|ticket|' . $nick . '|' . wire_who($room) . '|' . (int) floor($now / 3600)), 0, 12);
}

function wire_ticket_ok($room, $nick, $ticket, $now)
{
    return is_string($ticket) && (hash_equals(wire_ticket($room, $nick, $now), $ticket)
                                  || hash_equals(wire_ticket($room, $nick, $now - 3600), $ticket));
}
