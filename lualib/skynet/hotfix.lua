-- Lua热更新实现
-- 用途：在生产环境中快速修复Bug，无需停机维护
-- 原理：利用_ENV环境，在加载时把数据加载到_ENV下，然后通过对比方式修改_G底下的值

local lfs = require "lfs"

local M = {}

-- 配置常量
local CONFIG = {
	_ENV = true,
	skynet = true,
	lfs = true,
	package = true,
	debug = true,
	coroutine = true,
	io = true,
	os = true,
	string = true,
	table = true,
	math = true,
	utf8 = true,
}
setmetatable(CONFIG, { __index = _G })	

-- 防止重复的table替换，造成死循环
local visited_sig = {}

local print_flag = true

local function debug_print(...)
	if print_flag then
		print(...)
	end
end

-- 安全的字符串拼接
local function safe_concat(...)
	local args = {...}
	local result = ""
	for i = 1, #args do
		if args[i] then
			result = result .. args[i]
		end
	end
	return result
end

-- 生成缩进字符串
local function get_indent(depth)
	local indent = ""
	for i = 1, depth do
		indent = indent .. "  "
	end
	return indent
end

-- @return value 要使用的那个值
local function update_upvalue(new_v, old_v, field, path)
	local new_type = type(new_v)
	local old_type = type(old_v)
	if new_type ~= old_type then return new_v end

	if new_type == 'table' then
		local new_value
		for _field, _value in pairs(old_v) do
			new_value = new_v[_field]
			if new_value then
				if type(new_value) == 'table' then
					new_v[_field] = update_upvalue(new_value, _value, _field, path .. "->" .. _field)
				elseif type(new_value) == 'function' then
					new_v[_field] = update_upvalue(new_value, _value, _field, path .. "->" .. _field)
				else
					new_v[_field] = _value
				end
			end
		end
		return new_v
	elseif new_type == 'function' then
		local upvalue_map = {}
		for i = 1, math.huge do
			local name, value = debug.getupvalue(old_v, i)
			if not name then break end

			if not CONFIG[name] then
				upvalue_map[name] = value
			end
		end

		local old_value
		for i = 1, math.huge do
			local name, value = debug.getupvalue(new_v, i)
			if not name then break end

			old_value = upvalue_map[name]

			if old_value and old_value ~= value then
				-- table: 旧的table 里的值添加到新的中
				-- function: 函数用新的,upvalue 递归
				-- other: 用旧的
				value = update_upvalue(value, old_value, name, path .. "->" .. name)
				debug.setupvalue(new_v, i, value)
			end
		end

		return new_v
	else
		return old_v
	end
end

-- 更新函数，处理upvalue的对比和替换
local function update_func(new_env, old_env, field, path)
	if not new_env or not old_env or not field then return end
	
	local old_func = old_env[field]
	local new_func = new_env[field]
	if not old_func or not new_func then return end
	if old_func == new_func then return end
	if type(old_func) ~= type(new_func) then return end

	local upvalue_map = {}
	for i = 1, math.huge do
		local name, value = debug.getupvalue(old_func, i)
		if not name then break end

		if not CONFIG[name] then
			upvalue_map[name] = value
		end
	end

	local old_value
	for i = 1, math.huge do
		local name, value = debug.getupvalue(new_func, i)
		if not name then break end

		old_value = upvalue_map[name]

		if old_value and old_value ~= value then
			-- table: 旧的table 里的值添加到新的中
			-- function: 函数用新的,upvalue 递归
			-- other: 用旧的
			value = update_upvalue(value, old_value, name, path .. "->" .. name)
			debug.setupvalue(new_func, i, value)
		end
	end
end

-- 更新table，处理table内容的对比和替换
local function update_table(new_env, old_env, field, path)
	if not field or CONFIG[field] then return end

	-- 都不存在的字段
	if not new_env[field] or not old_env[field] then
		debug_print(string.format("[热更新] 字段值:%s 都不存在.", field))
		return
	end

	-- 值的类型不同
	local old_value = old_env[field]
	local new_value = new_env[field]
	if type(old_value) ~= type(new_value) then
		debug_print(string.format("[热更新] 字段值:%s 类型不同, 旧值:%s, 新值:%s", field, old_value, new_value))
		return
	end

	-- 更新旧表中存在的字段
	for _field, _value in pairs(old_value) do
		if type(_value) == 'table' then
			-- 递归处理嵌套的table
			update_table(new_value, old_value, _field, path .. "." .. _field)
		elseif type(_value) == 'function' then
			-- 用新的函数
			update_func(new_value, old_value, _field, path .. "." .. _field)
		else
			-- 使用旧的
			new_value[_field] = _value
		end

		debug_print(string.format("[热更新] 更新字段:%s, 值:%s", path .. "." .. _field, old_value[_field]))
	end

	-- 添加新表中存在的字段
	for _field, _value in pairs(new_value) do
		if not old_value[_field] then
			old_value[_field] = _value
			debug_print(string.format("[热更新] 添加字段:%s, 值:%s", path .. "." .. _field, old_value[_field]))
		end
	end
end

-- 对比新旧两个 env 的内容
local function check_env(new_env, old_env)
	if not new_env or not old_env then
		debug_print(string.format("[热更新] 存在未知的环境, 旧环境地址:%s, 新环境地址:%s", old_env or "nil", new_env or "nil"))
		return
	end

	-- 替换和添加旧环境中存在的字段
	for field, value in pairs(new_env) do
		if type(value) == 'table' then
			-- table 用旧的,替换表里的内容
			update_table(new_env, old_env, field, "env")
		elseif type(value) == 'function' then
			-- function 用旧的,替换函数的 upvalue
			update_func(new_env, old_env, field, "env")
		else
			-- 值用新的
			old_env[field] = value
		end
	end

	-- 删除旧的环境的值
	for field, value in pairs(old_env) do
		if not new_env[field] then
			old_env[field] = nil
		end
	end
end

-- 对整个文件进行热更新
function M.hotfix_file(path)
	if not path then
		debug_print("文件路径为空")
		return false
	end

	local module_info = package.loadinfo[path]
	if not module_info then
		debug_print(string.format("文件未加载: %s", path))
		return false
	end

	local old_env = module_info.env
	if not old_env then
		debug_print(string.format("文件代码环境不存在: %s", path))
		return false
	end

	local file_str
	local fp = io.open(path, "r")
	if not fp then
		debug_print(string.format("无法打开文件: %s", path))
		return false
	end
	
	local file_str = fp:read('*all')
	fp:close()
	
	if not file_str then
		debug_print(string.format("文件内容为空: %s", path))
		return false
	end
	
	debug_print(string.format("文件大小: %d 字节", #file_str))
	
	-- 加载代码块
	local new_env = {}
	setmetatable(new_env, { __index = _G })
	local f, load_err = load(file_str, path, 't', new_env)
	if not f then
		debug_print(string.format("Failed to load file: %s, error: %s", path, load_err or "unknown error"))
		return false
	end
		
	-- 执行代码块
	local ok, result = pcall(f)
	if not ok then
		debug_print(string.format("Failed to execute file: %s, error: %s", path, result or "unknown error"))
		return false
	end

	check_env(new_env, old_env)
	
	debug_print(string.format("=== 热更新完成: %s ===", path))
	return true
end

-- 检查并更新 loadinfo 中的 loadtime
function M.CheckHotFix(not_print)
	-- 是否打印日志
	print_flag = not not_print

	if not package.loadinfo then
		debug_print("package.loadinfo 不存在")
		return false
	end
	
	debug_print("=== 开始检查热更新 ===")
	
	-- 遍历 loadinfo 中的所有文件
	local fileInfo
	for filename, module_info in pairs(package.loadinfo) do
		if not module_info.result then
			debug_print(string.format("[检查] 处理文件: %s", filename))
			fileInfo = lfs.attributes(filename)
			if fileInfo then
				if not module_info.loadtime then
					-- 没有 loadtime，获取并保存
					module_info.loadtime = fileInfo.modification
					debug_print(string.format("[检查] 设置文件修改时间: %s -> %s", filename, os.date("%Y-%m-%d %H:%M:%S", fileInfo.modification)))
				else
					if module_info.loadtime ~= fileInfo.modification then
						debug_print(string.format("[检查] 文件 %s 修改时间发生变化: %s -> %s", filename, os.date("%Y-%m-%d %H:%M:%S", module_info.loadtime), os.date("%Y-%m-%d %H:%M:%S", fileInfo.modification)))

						-- 更新修改时间
						module_info.loadtime = fileInfo.modification

						-- 执行热更新
						local success = M.hotfix_file(filename)
						if success then
							debug_print(string.format("[检查] 热更新成功: %s", filename))
						else
							debug_print(string.format("[检查] 热更新失败: %s", filename))
						end
					end
				end
			else
				debug_print(string.format("[检查] 无法获取文件信息: %s", filename))
			end
		end
	end
end

return M




--[[
全局 table
	以新表为准,保存数据的模块不允许热更, 否则会导致数据丢失








]]