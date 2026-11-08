<?php
// The Wire's door for programs: the browser page and Farglade's wire program.
//
//   GET  api.php?op=hello                        what this is
//   GET  api.php?op=read&since=<id>&nick=<name>  the lines after <id> (the last forty when none is given)
//   POST api.php   op=say  nick=<name> text=<words> [kind=act]
// Every answer is JSON with "ok". Nothing is said by GET: a link cannot speak.

define('WIRE', 1);
require __DIR__ . '/wire.php';

header('Content-Type: application/json; charset=us-ascii');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

function answer($code, $body)
{
    http_response_code($code);
    echo json_encode($body);
    exit;
}

$post = $_SERVER['REQUEST_METHOD'] === 'POST';
$ask = $post ? $_POST : $_GET;
$op = isset($ask['op']) && is_string($ask['op']) ? $ask['op'] : '';
$now = time();

if ($op === 'hello') {
    answer(200, array('ok' => true, 'wire' => WIRE_PROTOCOL, 'room' => WIRE_ROOM,
                      'limits' => array('nick' => WIRE_NICK, 'text' => WIRE_TEXT, 'lines' => WIRE_LINES)));
}

if ($op === 'read') {
    $since = isset($_GET['since']) ? max(0, (int) $_GET['since']) : 0;
    $nick = wire_nick(isset($_GET['nick']) ? $_GET['nick'] : '');
    $result = wire_with(function (&$room) use ($since, $nick, $now) {
        $changed = wire_seen($room, $nick, $now);
        $lines = wire_after($room, $since, $since ? 100 : 40);
        return array(array('ok' => true, 'wire' => WIRE_PROTOCOL, 'now' => $now, 'last' => (int) $room['next'] - 1,
                           'lines' => $lines, 'here' => wire_here($room, $now)), $changed);
    });
    if ($result === null) {
        answer(503, array('ok' => false, 'why' => 'the room cannot be opened on this host.'));
    }
    answer(200, $result);
}

if (!$post) {
    answer($op === 'say' ? 405 : 400,
           array('ok' => false, 'why' => $op === '' ? 'no op was named.' : 'that is asked by POST, or is not known here.'));
}

if ($op === 'say') {
    $nick = wire_nick(isset($_POST['nick']) ? $_POST['nick'] : '');
    $text = wire_text(isset($_POST['text']) ? $_POST['text'] : '');
    $kind = isset($_POST['kind']) && $_POST['kind'] === 'act' ? 'act' : 'say';
    $result = wire_with(function (&$room) use ($nick, $text, $kind, $now) {
        $said = wire_say($room, $nick, $text, $kind, $now);
        return array($said, $said[0] > 0);
    });
    if ($result === null) {
        answer(503, array('ok' => false, 'why' => 'the room cannot be opened on this host.'));
    }
    if (!$result[0]) {
        answer(strpos($result[1], 'slow down') === 0 || strpos($result[1], 'the room is loud') === 0 ? 429 : 400,
               array('ok' => false, 'why' => $result[1]));
    }
    answer(200, array('ok' => true, 'id' => $result[0]));
}

answer(400, array('ok' => false, 'why' => 'that op is not known here.'));
