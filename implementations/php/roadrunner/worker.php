<?php
// RoadRunner worker entry point (PSR-7): the script and its PDO connection live across requests.
// Environment: BLOG_DSN.
require __DIR__ . '/vendor/autoload.php';
require __DIR__ . '/../blog.php';

use Nyholm\Psr7\Factory\Psr17Factory;
use Nyholm\Psr7\Response;
use Spiral\RoadRunner\Http\PSR7Worker;
use Spiral\RoadRunner\Worker;

$factory = new Psr17Factory();
$worker = new PSR7Worker(Worker::create(), $factory, $factory, $factory);
$db = blog_connect(getenv('BLOG_DSN'));

while ($request = $worker->waitRequest()) {
	[$status, $body] = blog_handle($db, $request->getUri()->getPath(), $request->getQueryParams(), $request->getHeaderLine('Authorization'));
	$worker->respond(new Response($status, ['Content-Type' => 'application/json'], $body));
}
