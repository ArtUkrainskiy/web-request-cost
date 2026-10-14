<?php
// Swoole entry point: BLOG_WORKERS worker processes, a coroutine per request, a PDOPool of BLOG_POOL
// connections per worker. Environment: BLOG_DRIVER (pgsql|mysql), BLOG_DB_PORT, BLOG_ADDR (host:port).
require __DIR__ . '/../blog.php';

use Swoole\Database\PDOConfig;
use Swoole\Database\PDOPool;
use Swoole\Http\Request;
use Swoole\Http\Response;
use Swoole\Http\Server;

[$host, $port] = explode(':', getenv('BLOG_ADDR'));
$server = new Server($host, (int) $port);
$server->set([
	'worker_num' => (int) (getenv('BLOG_WORKERS') ?: 8),
	'enable_coroutine' => true,
	'hook_flags' => SWOOLE_HOOK_ALL,
	'log_level' => SWOOLE_LOG_WARNING,
	'http_compression' => false,
]);

$pool = null;
$server->on('workerStart', static function () use (&$pool): void {
	$driver = getenv('BLOG_DRIVER');
	$config = (new PDOConfig())
		->withDriver($driver)
		->withHost(getenv('BLOG_DB_HOST') ?: '127.0.0.1')
		->withPort((int) getenv('BLOG_DB_PORT'))
		->withDbName('bench')
		->withUsername($driver === 'pgsql' ? 'postgres' : 'root')
		->withPassword('bench')
		->withOptions([PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_EMULATE_PREPARES => getenv('BLOG_EMULATE_PREPARES') === '1']);
	if ($driver === 'mysql') {
		$config = $config->withCharset('utf8mb4');
	}
	$pool = new PDOPool($config, (int) (getenv('BLOG_POOL') ?: 3));
});

$server->on('request', static function (Request $request, Response $response) use (&$pool): void {
	[$status, $body] = blog_handle([static fn () => $pool->get(), static fn (object $db) => $pool->put($db)],
		parse_url($request->server['request_uri'], PHP_URL_PATH), $request->get ?? [], $request->header['authorization'] ?? '');
	$response->status($status);
	$response->header('Content-Type', 'application/json');
	$response->end($body);
});

$server->start();
