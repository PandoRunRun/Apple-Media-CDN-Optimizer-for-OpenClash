-- Compatible with Lua 5.1 and Lua 5.3+ (does not use deprecated module() function)
local M = {}

function M.index()
	if not nixio.fs.access("/etc/config/apple_cdn_opt") then
		return
	end

	-- Menu entry (CBI settings page)
	entry({"admin", "services", "apple_cdn_opt"}, cbi("apple_cdn_opt"), _("Apple CDN Optimizer"), 60).dependent = true

	-- Register parent API node to prevent "Access Violation: has no parent node"
	entry({"admin", "services", "apple_cdn_opt_api"}, nil, nil).dependent = true

	-- Isolated API endpoints to avoid routing conflicts
	entry({"admin", "services", "apple_cdn_opt_api", "status"}, call("action_status")).leaf = true
	entry({"admin", "services", "apple_cdn_opt_api", "run"}, call("action_run")).leaf = true
	entry({"admin", "services", "apple_cdn_opt_api", "log"}, call("action_log")).leaf = true
	entry({"admin", "services", "apple_cdn_opt_api", "hosts"}, call("action_hosts")).leaf = true
end

-- Reads and outputs the optimization results JSON
function M.action_status()
	local nixio = require "nixio"
	local data = ""
	local f = io.open("/var/run/apple_cdn_opt.json", "r")
	if f then
		data = f:read("*all")
		f:close()
	else
		data = '{"status": "not_run", "domains": {}}'
	end
	luci.http.prepare_content("application/json")
	luci.http.write(data)
end

-- Triggers the optimizer script in the background
function M.action_run()
	-- 1. Synchronously reset log file
	local f = io.open("/var/run/apple_cdn_opt.log", "w")
	if f then
		f:write("开始触发测速优化任务...\n")
		f:close()
	end
	
	-- 2. Synchronously write status JSON as "running" to prevent frontend race condition
	local f_json = io.open("/var/run/apple_cdn_opt.json", "w")
	if f_json then
		f_json:write('{"status": "running", "domains": {}}')
		f_json:close()
	end
	
	-- 3. Execute script in the background and redirect output to log file in /var/run/
	os.execute("/usr/share/apple-cdn-opt/apple-cdn-opt.sh >/var/run/apple_cdn_opt.log 2>&1 &")
	
	luci.http.prepare_content("application/json")
	luci.http.write('{"status": "running"}')
end

-- Exposes the real-time execution log of the script
function M.action_log()
	local data = ""
	local f = io.open("/var/run/apple_cdn_opt.log", "r")
	if f then
		data = f:read("*all")
		f:close()
	else
		data = "暂无测速优化日志。\n"
	end
	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write(data)
end

-- Exposes the generated hosts file contents
function M.action_hosts()
	local data = ""
	local f = io.open("/etc/apple_cdn_opt.hosts", "r")
	if f then
		data = f:read("*all")
		f:close()
	else
		data = "暂无已生成的 Hosts 优选规则。\n"
	end
	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write(data)
end

return M
