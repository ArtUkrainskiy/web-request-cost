<?php
// FrankenPHP worker entry point: the script and its PDO connection live across requests.
// Environment: BLOG_DSN.
require __DIR__ . '/../blog.php';

ignore_user_abort(true);
$db = blog_connect(getenv('BLOG_DSN') ?: $_SERVER['BLOG_DSN']);
$handler = static function () use ($db): void {
	[$status, $body] = blog_handle($db, parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH), $_GET, $_SERVER['HTTP_AUTHORIZATION'] ?? '');
	http_response_code($status);
	header('Content-Type: application/json');
	echo $body;
};
while (frankenphp_handle_request($handler)) {
	gc_collect_cycles();
}
