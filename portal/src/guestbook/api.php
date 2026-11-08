<?php
// The guestbook's door for programs: the browser page.
//
//   GET  api.php?op=hello                 what this is
//   GET  api.php?op=read&before=<id>      a page of the book, newest first (the newest when none is given)
//   POST api.php   op=sign  name=<name> text=<words>
// Every answer is JSON with "ok". Nothing is signed by GET: a link cannot write in the book.

define('BOOK', 1);
require __DIR__ . '/book.php';

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
    answer(200, array('ok' => true, 'book' => BOOK_PROTOCOL,
                      'limits' => array('name' => BOOK_NAME, 'text' => BOOK_TEXT, 'kept' => BOOK_KEPT, 'page' => BOOK_PAGE)));
}

if ($op === 'read') {
    $before = isset($_GET['before']) ? max(0, (int) $_GET['before']) : 0;
    $result = book_with(function (&$book) use ($before) {
        $page = book_page($book, $before, BOOK_PAGE);
        return array(array('ok' => true, 'book' => BOOK_PROTOCOL, 'entries' => $page[0], 'more' => $page[1],
                           'count' => count($book['entries'])), false);
    });
    if ($result === null) {
        answer(503, array('ok' => false, 'why' => 'the book cannot be opened on this host.'));
    }
    answer(200, $result);
}

if (!$post) {
    answer($op === 'sign' ? 405 : 400,
           array('ok' => false, 'why' => $op === '' ? 'no op was named.' : 'that is asked by POST, or is not known here.'));
}

if ($op === 'sign') {
    $name = book_name(isset($_POST['name']) ? $_POST['name'] : '');
    $text = book_text(isset($_POST['text']) ? $_POST['text'] : '');
    $result = book_with(function (&$book) use ($name, $text, $now) {
        $signed = book_sign($book, $name, $text, 'web', $now);
        return array($signed, $signed[0] > 0);
    });
    if ($result === null) {
        answer(503, array('ok' => false, 'why' => 'the book cannot be opened on this host.'));
    }
    if (!$result[0]) {
        answer(strpos($result[1], 'wait a little') === 0 || strpos($result[1], 'the book is busy') === 0 ? 429 : 400,
               array('ok' => false, 'why' => $result[1]));
    }
    answer(200, array('ok' => true, 'id' => $result[0]));
}

answer(400, array('ok' => false, 'why' => 'that op is not known here.'));
