-- skynet module two-step initialize . When you require a skynet module :
-- 1. Run module main function as official lua module behavior.
-- 2. Run the functions register by skynet.init() during the step 1,
--      unless calling `require` in main thread .
-- If you call `require` in main thread ( service main function ), the functions
-- registered by skynet.init() do not execute immediately, they will be executed
-- by skynet.start() before start function.

local M = {}

local mainthread, ismain = coroutine.running()
assert(ismain, "skynet.require must initialize in main thread")
local lfs = require "lfs"

local context = {
	[mainthread] = {},
}

do
	local require = _G.require
	local loaded = package.loaded
	local loading = {}

	function M.require(name)
		local m = loaded[name]
		if m then
			if type(m) == "table" then
				if m.__RESULT__ then
					return m.__RESULT__
				end
				if m.__ENV__ then
					return m.__ENV__
				end
			end

			return m
		end

		local co, main = coroutine.running()
		if main then
			return require(name)
		end

		local filename = package.searchpath(name, package.path)
		if not filename then
			print(string.format("module '%s' not found", name))
			return require(name)
		end

		-- 创建环境，使用 _G 作为基础环境
		local env = {}
		setmetatable(env, { __index = _G })
		
		local modfunc = loadfile(filename, "bt", env)
		if not modfunc then
			return require(name)
		end

		local loading_queue = loading[name]
		if loading_queue then
			assert(loading_queue.co ~= co, "circular dependency")
			-- Module is in the init process (require the same mod at the same time in different coroutines) , waiting.
			local skynet = require "skynet"
			loading_queue[#loading_queue+1] = co
			skynet.wait(co)
			local m = loaded[name]
			if m == nil then
				error(string.format("require %s failed", name))
			end
			return m
		end

		loading_queue = {co = co}
		loading[name] = loading_queue

		local old_init_list = context[co]
		local init_list = {}
		context[co] = init_list

		-- We should call modfunc in lua, because modfunc may yield by calling M.require recursive.
		local function execute_module()
			local m = modfunc(name, filename)

			for _, f in ipairs(init_list) do
				f()
			end

			print(string.format("导入模块:%s, 路径:%s", name, filename))

			local fileInfo = lfs.attributes(filename)
			if not fileInfo then
				print(string.format("无法获取文件信息: %s", filename))
			end

			loaded[name] = {
				__PATH__ = filename,
				__RESULT__ = m,
				__ENV__ = env,
				__LOADTIME__ = fileInfo and fileInfo.modification,
			}
		end

		local ok, err = xpcall(execute_module, debug.traceback)

		context[co] = old_init_list

		local waiting = #loading_queue
		if waiting > 0 then
			local skynet = require "skynet"
			for i = 1, waiting do
				skynet.wakeup(loading_queue[i])
			end
		end
		loading[name] = nil

		if ok then
			return loaded[name].__RESULT__ or loaded[name].__ENV__
		else
			error(err)
		end
	end
end

function M.init_all()
	for _, f in ipairs(context[mainthread]) do
		f()
	end
	context[mainthread] = nil
end

function M.init(f)
	assert(type(f) == "function")
	local co = coroutine.running()
	table.insert(context[co], f)
end

return M