// Blog API logic from spec/spec.md, shared by the node:http and Fastify servers.
// createBlog() returns { acquire, release, authenticate, callUpstream, listPosts, showPost, handle };
// handle(path, query, authorization) → [status, json string] serves node:http. The statements of a
// request share one connection (acquire/release), returned to the pool while the upstream is awaited.
import { createHash } from 'node:crypto';
import http from 'node:http';
import pg from 'pg';
import mysql from 'mysql2/promise';

const NOW = '2026-10-13 00:00:00';
const upstream = process.env.BLOG_UPSTREAM;
// Keep-alive connections to the upstream, no limit on sockets per host.
const agent = new http.Agent({ keepAlive: true, maxSockets: Infinity });

function get(url) {
	return new Promise((resolve, reject) => {
		http.get(url, { agent }, (res) => {
			let body = '';
			res.setEncoding('utf8');
			res.on('data', (chunk) => (body += chunk));
			res.on('end', () => resolve(body));
			res.on('error', reject);
		}).on('error', reject);
	});
}

// BIGINT (20) and COUNT(*) come back as strings from pg; the API returns numbers.
pg.types.setTypeParser(20, (v) => Number(v));

export function createBlog({ driver, dsn, pool }) {
	const isPg = driver === 'pg';
	let acquire, query;
	if (isPg) {
		const p = new pg.Pool({ connectionString: dsn, max: pool });
		const pgSql = new Map(); // ? placeholders → $1, $2, …
		acquire = () => p.connect();
		query = async (c, sql, params) => {
			let text = pgSql.get(sql);
			if (text === undefined) {
				let n = 0;
				text = sql.replace(/\?/g, () => '$' + ++n);
				pgSql.set(sql, text);
			}
			return (await c.query({ text, values: params, rowMode: 'array' })).rows;
		};
	} else {
		const p = mysql.createPool({ uri: dsn, connectionLimit: pool, rowsAsArray: true });
		acquire = () => p.getConnection();
		query = async (c, sql, params) => (await c.query(sql, params))[0];
	}
	const release = (c) => c.release();
	const at = (col) => (isPg ? `to_char(${col}, 'YYYY-MM-DD HH24:MI:SS')` : `DATE_FORMAT(${col}, '%Y-%m-%d %H:%i:%s')`);
	const atom = (s) => s.slice(0, 10) + 'T' + s.slice(11) + '+00:00';
	const placeholders = (n) => Array(n).fill('?').join(', ');

	// The user of a valid "Bearer <token>", or null.
	async function authenticate(c, auth = '') {
		const hash = createHash('sha256').update(auth.slice(7)).digest('hex');
		const u = await query(c, 'SELECT u.id, u.username FROM blog_session s JOIN symfony_demo_user u ON u.id = s.user_id WHERE s.token_hash = ? AND s.expires_at > ?', [hash, NOW]);
		return auth.startsWith('Bearer ') && u.length ? { id: u[0][0], username: u[0][1] } : null;
	}

	async function callUpstream() {
		if (upstream) {
			const reply = await get(upstream);
			if (reply !== '{"ok":true}') throw new Error(`upstream: ${reply}`);
		}
	}

	async function listPosts(c, page) {
		const rows = await query(c, `SELECT p.id, p.title, p.slug, p.summary, ${at('p.published_at')}, u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id ORDER BY p.published_at DESC LIMIT 20 OFFSET ?`, [(page - 1) * 20]);
		const posts = [];
		const index = new Map();
		for (const r of rows) {
			const p = { id: r[0], title: r[1], slug: r[2], summary: r[3], published_at: atom(r[4]), author: { id: r[5], name: r[6] }, tags: [], comment_count: 0 };
			index.set(p.id, p);
			posts.push(p);
		}
		if (posts.length) {
			const ids = posts.map((p) => p.id);
			for (const [id, name] of await query(c, `SELECT pt.post_id, t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id IN (${placeholders(ids.length)}) ORDER BY pt.post_id, t.name`, ids)) {
				index.get(id).tags.push(name);
			}
			for (const [id, n] of await query(c, `SELECT post_id, COUNT(*) FROM symfony_demo_comment WHERE post_id IN (${placeholders(ids.length)}) GROUP BY post_id`, ids)) {
				index.get(id).comment_count = Number(n);
			}
		}
		return posts;
	}

	// The post with its tags and comments, or null.
	async function showPost(c, slug) {
		const r = (await query(c, `SELECT p.id, p.title, p.slug, p.summary, p.content, ${at('p.published_at')}, u.id, u.full_name FROM symfony_demo_post p JOIN symfony_demo_user u ON u.id = p.author_id WHERE p.slug = ?`, [slug]))[0];
		if (!r) return null;
		const post = { id: r[0], title: r[1], slug: r[2], summary: r[3], content: r[4], published_at: atom(r[5]), author: { id: r[6], name: r[7] }, tags: [], comments: [] };
		post.tags = (await query(c, 'SELECT t.name FROM symfony_demo_post_tag pt JOIN symfony_demo_tag t ON t.id = pt.tag_id WHERE pt.post_id = ? ORDER BY t.name', [post.id])).map((t) => t[0]);
		for (const m of await query(c, `SELECT c.id, u.full_name, c.content, ${at('c.published_at')} FROM symfony_demo_comment c JOIN symfony_demo_user u ON u.id = c.author_id WHERE c.post_id = ? ORDER BY c.published_at, c.id`, [post.id])) {
			post.comments.push({ id: m[0], author: m[1], content: m[2], published_at: atom(m[3]) });
		}
		return post;
	}

	async function handle(path, searchParams, auth) {
		let c = await acquire();
		try {
			const user = await authenticate(c, auth);
			if (!user) return [401, JSON.stringify({ error: 'unauthorized' })];
			if (upstream) {
				release(c);
				c = null;
				await callUpstream();
				c = await acquire();
			}
			if (path === '/posts') {
				const page = searchParams.has('page') ? parseInt(searchParams.get('page'), 10) || 0 : 1;
				return [200, JSON.stringify({ user, page, posts: await listPosts(c, page) })];
			}
			if (path.startsWith('/posts/')) {
				const post = await showPost(c, decodeURIComponent(path.slice(7)));
				return post ? [200, JSON.stringify({ user, post })] : [404, JSON.stringify({ error: 'not found' })];
			}
			return [404, JSON.stringify({ error: 'not found' })];
		} finally {
			if (c) release(c);
		}
	}

	return { acquire, release, authenticate, callUpstream, listPosts, showPost, handle };
}
