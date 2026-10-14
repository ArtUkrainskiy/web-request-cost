<?php
// Adds 1,000 reader users and their session tokens to PostgreSQL and MySQL (see spec.md).
//   php seed.php <pgsql dsn> <mysql dsn>

[$_, $pgDsn, $myDsn] = $argv;

foreach (['pgsql' => $pgDsn, 'mysql' => $myDsn] as $kind => $dsn) {
	$db = new PDO($dsn, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
	$db->exec('DROP TABLE IF EXISTS blog_session');
	$db->exec('DELETE FROM symfony_demo_user WHERE id > 3');
	$db->exec($kind === 'pgsql'
		? 'CREATE TABLE blog_session (token_hash CHAR(64) PRIMARY KEY, user_id BIGINT NOT NULL, expires_at TIMESTAMP NOT NULL)'
		: 'CREATE TABLE blog_session (token_hash CHAR(64) PRIMARY KEY, user_id BIGINT NOT NULL, expires_at DATETIME NOT NULL) CHARACTER SET ascii');
	$db->beginTransaction();
	$user = $db->prepare('INSERT INTO symfony_demo_user (id, full_name, username, email, password, roles) VALUES (?, ?, ?, ?, ?, ?)');
	$session = $db->prepare('INSERT INTO blog_session (token_hash, user_id, expires_at) VALUES (?, ?, ?)');
	for ($n = 1; $n <= 1000; $n++) {
		$id = 3 + $n;
		$user->execute([$id, "Reader $n", "reader$n", "reader$n@example.com", '-', '["ROLE_USER"]']);
		$session->execute([hash('sha256', "tok-$n"), $id, '2027-01-01 00:00:00']);
	}
	$db->commit();
	// Indexes a real blog has: list order, slug lookup, comments of a post.
	$indexes = ['post_published' => 'symfony_demo_post(published_at)', 'post_slug' => 'symfony_demo_post(slug' . ($kind === 'mysql' ? '(191)' : '') . ')', 'comment_post' => 'symfony_demo_comment(post_id)'];
	foreach ($indexes as $name => $on) {
		if ($kind === 'pgsql') {
			$db->exec("CREATE INDEX IF NOT EXISTS $name ON $on");
		} elseif (!$db->query("SELECT 1 FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND INDEX_NAME = '$name'")->fetchColumn()) {
			$db->exec("CREATE INDEX $name ON $on");
		}
	}
	$db->exec($kind === 'pgsql' ? 'ANALYZE' : 'ANALYZE TABLE symfony_demo_post, symfony_demo_comment, symfony_demo_user, blog_session');
	echo "$kind ", $db->query('SELECT COUNT(*) FROM blog_session')->fetchColumn(), " sessions\n";
}
