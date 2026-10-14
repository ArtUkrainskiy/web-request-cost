<?php
// PHP-FPM entry point. Environment: BLOG_DSN, BLOG_PERSISTENT=1 for persistent connections.
require __DIR__ . '/../blog.php';

$db = blog_connect(getenv('BLOG_DSN'), getenv('BLOG_PERSISTENT') === '1');
[$status, $body] = blog_handle($db, parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH), $_GET, $_SERVER['HTTP_AUTHORIZATION'] ?? '');
http_response_code($status);
header('Content-Type: application/json');
echo $body;
