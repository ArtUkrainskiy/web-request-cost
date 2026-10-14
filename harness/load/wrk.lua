-- Replays requests.txt ("<path> <token>" per line); each wrk thread starts at its own offset.
-- REQUESTS env: path to the list.
local lines = {}
for line in io.lines(os.getenv("REQUESTS")) do
	local path, token = line:match("^(%S+) (%S+)$")
	lines[#lines + 1] = { path = path, auth = "Bearer " .. token }
end

local counter = 0
local threads = {}
function setup(thread)
	counter = counter + 1
	thread:set("offset", counter * 4999)
	threads[#threads + 1] = thread
end

local i = 0
function init(args)
	i = offset or 0
end

-- Per-thread counts of 200, 401, 404, 5xx, other statuses and of response body bytes.
s200, s401, s404, s5xx, sother, bytes = 0, 0, 0, 0, 0, 0
function response(status, headers, body)
	if status == 200 then s200 = s200 + 1
	elseif status == 401 then s401 = s401 + 1
	elseif status == 404 then s404 = s404 + 1
	elseif status >= 500 then s5xx = s5xx + 1
	else sother = sother + 1 end
	bytes = bytes + #body
end

function request()
	i = i + 1
	local r = lines[(i % #lines) + 1]
	return wrk.format("GET", r.path, { ["Authorization"] = r.auth })
end

function done(summary, latency, requests)
	local t = { s200 = 0, s401 = 0, s404 = 0, s5xx = 0, sother = 0, bytes = 0 }
	for _, thread in ipairs(threads) do
		for k in pairs(t) do t[k] = t[k] + thread:get(k) end
	end
	io.write(string.format('WRKJSON {"requests":%d,"duration_us":%d,"non2xx":%d,"errors":%d,"p50_us":%d,"p90_us":%d,"p99_us":%d,"max_us":%d,"s200":%d,"s401":%d,"s404":%d,"s5xx":%d,"sother":%d,"body_bytes":%d}\n',
		summary.requests, summary.duration, summary.errors.status, summary.errors.connect + summary.errors.read + summary.errors.write + summary.errors.timeout,
		latency:percentile(50), latency:percentile(90), latency:percentile(99), latency.max,
		t.s200, t.s401, t.s404, t.s5xx, t.sother, t.bytes))
end
