// Sends every request of a list to a server and prints one hash over all
// "<status> <content-type> <body>" plus counts by status; servers must agree.
//   node verify.mjs <base url> <requests.txt> [limit] [concurrency] [canon]
// canon: the body is parsed and serialized again with object keys sorted, so escaping of "/" and
// of non-ASCII characters and the order of keys do not count; the content type is reduced to
// its media type.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const [base, file, limit = '0', conc = '8', mode = ''] = process.argv.slice(2);
let lines = readFileSync(file, 'utf8').trim().split('\n');
if (Number(limit) > 0) lines = lines.slice(0, Number(limit));

const sorted = (v) => (Array.isArray(v) ? v.map(sorted)
	: v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, sorted(v[k])])) : v);

const results = new Array(lines.length);
let next = 0;
async function worker() {
	while (next < lines.length) {
		const i = next++;
		const [path, token] = lines[i].split(' ');
		const r = await fetch(base + path, { headers: { Authorization: `Bearer ${token}` } });
		let body = await r.text();
		let type = r.headers.get('content-type');
		if (mode === 'canon') {
			body = JSON.stringify(sorted(JSON.parse(body)));
			type = type.split(';')[0].trim();
		}
		results[i] = `${r.status} ${type} ${body}`;
	}
}
await Promise.all(Array.from({ length: Number(conc) }, worker));

const h = createHash('sha256');
const byStatus = {};
for (const r of results) {
	h.update(r + '\n');
	const s = r.slice(0, 3);
	byStatus[s] = (byStatus[s] ?? 0) + 1;
}
console.log(JSON.stringify({ requests: lines.length, sha256: h.digest('hex'), byStatus, firstBytes: results[0].length }));
