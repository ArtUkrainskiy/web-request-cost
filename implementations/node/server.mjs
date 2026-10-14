// Blog API server: node:http or Fastify, in a cluster of BLOG_WORKERS processes sharing one port.
//   BLOG_SERVER=http|fastify BLOG_WORKERS=8 BLOG_DRIVER=pg|mysql BLOG_DSN=... BLOG_POOL=3 BLOG_ADDR=127.0.0.1:8082 node server.mjs
import cluster from 'node:cluster';
import http from 'node:http';
import { createBlog } from './blog.mjs';

const workers = Number(process.env.BLOG_WORKERS || 1);
const [host, port] = process.env.BLOG_ADDR.split(':');

if (cluster.isPrimary && workers > 1) {
	for (let i = 0; i < workers; i++) cluster.fork();
	cluster.on('exit', (w, code) => {
		console.error(`worker ${w.process.pid} exited with ${code}`);
		process.exit(1);
	});
} else {
	const blog = createBlog({ driver: process.env.BLOG_DRIVER, dsn: process.env.BLOG_DSN, pool: Number(process.env.BLOG_POOL || 3) });
	if (process.env.BLOG_SERVER === 'fastify') {
		const { default: Fastify } = await import('fastify');
		const app = Fastify({ logger: false });
		const author = { type: 'object', properties: { id: { type: 'integer' }, name: { type: 'string' } } };
		const user = { type: 'object', properties: { id: { type: 'integer' }, username: { type: 'string' } } };
		const tags = { type: 'array', items: { type: 'string' } };
		const error = { type: 'object', properties: { error: { type: 'string' } } };
		// Authentication (and the upstream call) for every request, before routing, as in the spec. The
		// request keeps one connection (req.db), returned to the pool around the upstream call and when the
		// response closes, whether it finished or the client went away.
		const done = (req) => {
			if (req.db) blog.release(req.db);
			req.db = null;
		};
		const take = async (req) => {
			req.db = await blog.acquire();
			if (req.closed) done(req);
		};
		app.addHook('onRequest', async (req, reply) => {
			reply.raw.on('close', () => {
				req.closed = true;
				done(req);
			});
			await take(req);
			if (!req.db) return;
			req.user = await blog.authenticate(req.db, req.headers.authorization);
			if (!req.user) return reply.code(401).send({ error: 'unauthorized' });
			if (process.env.BLOG_UPSTREAM) {
				done(req);
				await blog.callUpstream();
				await take(req);
			}
		});
		app.get('/posts', {
			schema: { response: { 200: { type: 'object', properties: { user, page: { type: 'integer' }, posts: { type: 'array', items: { type: 'object', properties: {
				id: { type: 'integer' }, title: { type: 'string' }, slug: { type: 'string' }, summary: { type: 'string' }, published_at: { type: 'string' },
				author, tags, comment_count: { type: 'integer' },
			} } } } } } },
		}, async (req) => {
			const page = req.query.page !== undefined ? parseInt(req.query.page, 10) || 0 : 1;
			return { user: req.user, page, posts: await blog.listPosts(req.db, page) };
		});
		app.get('/posts/:slug', {
			schema: { response: { 200: { type: 'object', properties: { user, post: { type: 'object', properties: {
				id: { type: 'integer' }, title: { type: 'string' }, slug: { type: 'string' }, summary: { type: 'string' }, content: { type: 'string' },
				published_at: { type: 'string' }, author, tags,
				comments: { type: 'array', items: { type: 'object', properties: { id: { type: 'integer' }, author: { type: 'string' }, content: { type: 'string' }, published_at: { type: 'string' } } } },
			} } } }, 404: error } },
		}, async (req, reply) => {
			const post = await blog.showPost(req.db, req.params.slug);
			return post ? { user: req.user, post } : reply.code(404).send({ error: 'not found' });
		});
		app.setNotFoundHandler((req, reply) => reply.code(404).send({ error: 'not found' }));
		await app.listen({ host, port: Number(port) });
	} else {
		http.createServer(async (req, res) => {
			try {
				const url = new URL(req.url, 'http://x');
				const [status, json] = await blog.handle(url.pathname, url.searchParams, req.headers.authorization);
				res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(json) });
				res.end(json);
			} catch (e) {
				console.error(e);
				res.writeHead(500);
				res.end();
			}
		}).listen(Number(port), host);
	}
}
