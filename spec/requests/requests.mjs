// Writes the fixed request list from ../spec.md: one "<path> <token>" per line.
//   node requests.mjs <slugs file> <count> <seed> [uniform|zipf] > requests.txt
// uniform: pages 1..150 and posts with equal probability (used for checking responses).
// zipf: page p with probability ∝ 1/p, post of recency rank r with probability ∝ 1/r
// (the slugs file is then ordered newest first) — the load list.
import { readFileSync } from 'node:fs';

const [slugFile, count = '20000', seed = '1', mode = 'uniform'] = process.argv.slice(2);
const slugs = readFileSync(slugFile, 'utf8').trim().split('\n');

// mulberry32: the same sequence on every machine.
let s = Number(seed) >>> 0;
const rand = () => {
	s = (s + 0x6d2b79f5) >>> 0;
	let t = s;
	t = Math.imul(t ^ (t >>> 15), t | 1);
	t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
	return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const pick = (n) => Math.floor(rand() * n);
// Zipf(s=1) over 1..n by inverse transform on the harmonic weights.
const zipfTable = (n) => {
	const c = [];
	let sum = 0;
	for (let k = 1; k <= n; k++) c.push((sum += 1 / k));
	return c.map((v) => v / sum);
};
const zipf = (table) => {
	const u = rand();
	let lo = 0, hi = table.length - 1;
	while (lo < hi) {
		const mid = (lo + hi) >> 1;
		if (table[mid] < u) lo = mid + 1; else hi = mid;
	}
	return lo;
};
const pages = zipfTable(150);
const posts = zipfTable(slugs.length);
const page = () => (mode === 'zipf' ? 1 + zipf(pages) : 1 + pick(150));
const slug = () => slugs[mode === 'zipf' ? zipf(posts) : pick(slugs.length)];

const out = [];
for (let i = 0; i < Number(count); i++) {
	const token = rand() < 0.01 ? 'tok-unknown' : `tok-${1 + pick(1000)}`;
	const path = rand() < 0.8 ? `/posts?page=${page()}` : `/posts/${slug()}`;
	out.push(`${path} ${token}`);
}
process.stdout.write(out.join('\n') + '\n');
