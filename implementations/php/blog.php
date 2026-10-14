<?php
// Blog API logic from spec/spec.md, shared by every PHP entry point (FPM, FrankenPHP worker,
// RoadRunner, Swoole). blog_handle() returns [status, JSON body].

const BLOG_NOW = '2026-10-13 00:00:00';
const BLOG_FLAGS = 0; // json_encode defaults

function blog_connect(string $dsn, bool $persistent = false): PDO
{
	$options = [
		PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
		PDO::ATTR_EMULATE_PREPARES => getenv('BLOG_EMULATE_PREPARES') === '1',
		PDO::ATTR_PERSISTENT => $persistent,
	];
	// BLOG_DISABLE_PREPARES=1 (PostgreSQL): statements with parameters but without a named prepared statement.
	if (getenv('BLOG_DISABLE_PREPARES') === '1' && str_starts_with($dsn, 'pgsql:')) {
		$options[Pdo\Pgsql::ATTR_DISABLE_PREPARES] = true;
	}
	return new PDO($dsn, null, null, $options);
}

/**
 * $db->prepare($sql), or with BLOG_STMT_CACHE=1 the statement prepared earlier on the same
 * connection object.
 */
function blog_prepare(object $db, string $sql): object
{
	static $enabled = null, $cache = null;
	$enabled ??= getenv('BLOG_STMT_CACHE') === '1';
	if (!$enabled) {
		return $db->prepare($sql);
	}
	$cache ??= new WeakMap();
	$statements = $cache[$db] ?? [];
	if (!isset($statements[$sql])) {
		$statements[$sql] = $db->prepare($sql);
		$cache[$db] = $statements;
	}
	return $statements[$sql];
}

function blog_atom(string $s): string
{
	return substr($s, 0, 10) . 'T' . substr($s, 11) . '+00:00';
}

/**
 * GET $url, which must answer {"ok":true}. Handles are pooled per process, so worker modes keep
 * their connections alive; under FPM a persistent share keeps the connection cache across requests.
 */
function blog_upstream(string $url): void
{
	static $idle = [];
	static $share = null;
	$ch = array_pop($idle);
	if ($ch === null) {
		$ch = curl_init($url);
		curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 30]);
		if (PHP_SAPI === 'fpm-fcgi') {
			$share ??= curl_share_init_persistent([CURL_LOCK_DATA_CONNECT, CURL_LOCK_DATA_DNS]);
			curl_setopt($ch, CURLOPT_SHARE, $share);
		}
	}
	try {
		$reply = curl_exec($ch);
		if ($reply !== '{"ok":true}') {
			throw new RuntimeException('upstream: ' . curl_error($ch));
		}
	} finally {
		$idle[] = $ch;
	}
}

function blog_placeholders(int $n): string
{
	return implode(', ', array_fill(0, $n, '?'));
}

/**
 * @param PDO|object|array{Closure, Closure} $connection PDO or a pool proxy, or [acquire, release]
 *        closures of a pool: the connection is then returned to the pool while the upstream is awaited
 * @return array{int, string}
 */
function blog_handle(object|array $connection, string $path, array $query, string $auth): array
{
	[$acquire, $release] = is_array($connection) ? $connection : [static fn () => $connection, static function (object $c): void {}];
	$db = $acquire();
	try {
		return blog_handle_with($db, $acquire, $release, $path, $query, $auth);
	} finally {
		if ($db !== null) {
			$release($db);
		}
	}
}

/** @return array{int, string} */
function blog_handle_with(?object &$db, Closure $acquire, Closure $release, string $path, array $query, string $auth): array
{
	$at = $db->getAttribute(PDO::ATTR_DRIVER_NAME) === 'pgsql' ? "to_char(%s, 'YYYY-MM-DD HH24:MI:SS')" : "DATE_FORMAT(%s, '%%Y-%%m-%%d %%H:%%i:%%s')";

	$st = blog_prepare($db, 'SELECT u.id, u.username FROM blog_session s JOIN symfony_demo_user u ON u.id = s.user_id WHERE s.token_hash = ? AND s.expires_at > ?');
	$st->execute([hash('sha256', substr($auth, 7)), BLOG_NOW]);
	$user = $st->fetch(PDO::FETCH_NUM);
	$st = null;
	if (!str_starts_with($auth, 'Bearer ') || $user === false) {
		return [401, json_encode(['error' => 'unauthorized'], BLOG_FLAGS)];
	}
	$user = ['id' => (int) $user[0], 'username' => $user[1]];

	$upstream = getenv('BLOG_UPSTREAM');
	if ($upstream) {
		$release($db);
		$db = null;
		blog_upstream($upstream);
		$db = $acquire();
	}

	if ($path === '/posts') {
		$page = (int) ($query['page'] ?? 1);
		$st = blog_prepare($db, 'SELECT p.id, p.title, p.slug, p.summary, ' . sprintf($at, 'p.published_at') . ', u.id, u.full_name
			FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id ORDER BY p.published_at DESC LIMIT 20 OFFSET ?');
		$st->bindValue(1, ($page - 1) * 20, PDO::PARAM_INT);
		$st->execute();
		$posts = [];
		foreach ($st->fetchAll(PDO::FETCH_NUM) as $r) {
			$posts[(int) $r[0]] = [
				'id' => (int) $r[0], 'title' => $r[1], 'slug' => $r[2], 'summary' => $r[3], 'published_at' => blog_atom($r[4]),
				'author' => ['id' => (int) $r[5], 'name' => $r[6]], 'tags' => [], 'comment_count' => 0,
			];
		}
		if ($posts) {
			$ids = array_keys($posts);
			$st = blog_prepare($db, 'SELECT pt.post_id, t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id
				WHERE pt.post_id IN (' . blog_placeholders(count($ids)) . ') ORDER BY pt.post_id, t.name');
			$st->execute($ids);
			foreach ($st->fetchAll(PDO::FETCH_NUM) as [$id, $name]) {
				$posts[$id]['tags'][] = $name;
			}
			$st = blog_prepare($db, 'SELECT post_id, COUNT(*) FROM symfony_demo_comment WHERE post_id IN (' . blog_placeholders(count($ids)) . ') GROUP BY post_id');
			$st->execute($ids);
			foreach ($st->fetchAll(PDO::FETCH_NUM) as [$id, $n]) {
				$posts[$id]['comment_count'] = (int) $n;
			}
		}
		return [200, json_encode(['user' => $user, 'page' => $page, 'posts' => array_values($posts)], BLOG_FLAGS)];
	}

	if (str_starts_with($path, '/posts/')) {
		$st = blog_prepare($db, 'SELECT p.id, p.title, p.slug, p.summary, p.content, ' . sprintf($at, 'p.published_at') . ', u.id, u.full_name
			FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id WHERE p.slug = ?');
		$st->execute([substr($path, 7)]);
		$r = $st->fetch(PDO::FETCH_NUM);
		$st = null;
		if ($r === false) {
			return [404, json_encode(['error' => 'not found'], BLOG_FLAGS)];
		}
		$id = (int) $r[0];
		$post = [
			'id' => $id, 'title' => $r[1], 'slug' => $r[2], 'summary' => $r[3], 'content' => $r[4], 'published_at' => blog_atom($r[5]),
			'author' => ['id' => (int) $r[6], 'name' => $r[7]], 'tags' => [], 'comments' => [],
		];
		$st = blog_prepare($db, 'SELECT t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id = ? ORDER BY t.name');
		$st->execute([$id]);
		$post['tags'] = $st->fetchAll(PDO::FETCH_COLUMN);
		$st = blog_prepare($db, 'SELECT c.id, u.full_name, c.content, ' . sprintf($at, 'c.published_at') . '
			FROM symfony_demo_comment c JOIN symfony_demo_user u ON u.id = c.author_id WHERE c.post_id = ? ORDER BY c.published_at, c.id');
		$st->execute([$id]);
		foreach ($st->fetchAll(PDO::FETCH_NUM) as $c) {
			$post['comments'][] = ['id' => (int) $c[0], 'author' => $c[1], 'content' => $c[2], 'published_at' => blog_atom($c[3])];
		}
		return [200, json_encode(['user' => $user, 'post' => $post], BLOG_FLAGS)];
	}

	return [404, json_encode(['error' => 'not found'], BLOG_FLAGS)];
}
