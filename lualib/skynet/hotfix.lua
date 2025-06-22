-- Lua热更新实现
-- 用途：在生产环境中快速修复Bug，无需停机维护
-- 原理：利用_ENV环境，在加载时把数据加载到_ENV下，然后通过对比方式修改_G底下的值

local lfs = require "lfs"

local M = {}

-- 配置常量
local CONFIG = {
    setmetatable = true,
    pairs = true,
    ipairs = true,
    next = true,
    require = true,
    _ENV = true,
    pcall = true,
    xpcall = true,
    load = true,
    loadfile = true,
}

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

-- 更新函数，处理upvalue的对比和替换
local function update_func(new_func, old_func, name, depth)
	if not new_func or not old_func then return end
	
	local indent = get_indent(depth)
	debug_print(string.format("%s[函数更新] 开始处理函数: %s (深度: %d)", indent, name, depth))
	
	-- 取得原函数所有的upvalue，保存起来
	local old_upvalue_map = {}
	local old_upvalue_count = 0
	for i = 1, math.huge do
		local name, value = debug.getupvalue(old_func, i)
		if not name then break end
		old_upvalue_map[name] = value
		old_upvalue_count = old_upvalue_count + 1
	end
	debug_print(string.format("%s[函数更新] 原函数有 %d 个upvalue", indent, old_upvalue_count))
	
	-- 遍历新函数的所有upvalue，根据名字和原值对比
	local new_upvalue_count = 0
	local updated_upvalue_count = 0
	for i = 1, math.huge do
		local name, value = debug.getupvalue(new_func, i)
		if not name then break end
		new_upvalue_count = new_upvalue_count + 1
		local old_value = old_upvalue_map[name]
		if old_value then
			debug_print(string.format("%s[函数更新] 处理upvalue: %s (类型: %s)", indent, name, type(value)))
			-- 如果原函数中有同名的upvalue，保持原值
			if type(old_value) ~= type(value) then
				-- 类型不同，使用原值
				debug_print(string.format("%s[函数更新]  类型不同，使用原值 (原类型: %s, 新类型: %s)", indent, type(old_value), type(value)))
				debug.setupvalue(new_func, i, old_value)
				updated_upvalue_count = updated_upvalue_count + 1
			elseif type(old_value) == 'function' then
				-- 都是函数，递归处理
				debug_print(string.format("%s[函数更新]  递归处理函数upvalue: %s", indent, name))
				update_func(value, old_value, name, depth + 1)
				updated_upvalue_count = updated_upvalue_count + 1
			elseif type(old_value) == 'table' then
				-- 都是table，递归处理
				debug_print(string.format("%s[函数更新]  递归处理table upvalue: %s", indent, name))
				update_table(value, old_value, name, depth + 1)
				-- 使用处理后的原值
				debug.setupvalue(new_func, i, old_value)
				updated_upvalue_count = updated_upvalue_count + 1
			else
				-- 其他类型，使用原值
				debug_print(string.format("%s[函数更新]  使用原值 (类型: %s)", indent, type(old_value)))
				debug.setupvalue(new_func, i, old_value)
				updated_upvalue_count = updated_upvalue_count + 1
			end
		else
			debug_print(string.format("%s[函数更新] 新upvalue: %s (类型: %s) - 保持新值", indent, name, type(value)))
		end
	end
	
	debug_print(string.format("%s[函数更新] 函数 %s 处理完成 (新upvalue: %d, 更新upvalue: %d)", indent, name, new_upvalue_count, updated_upvalue_count))
end

-- 更新table，处理table内容的对比和替换
local function update_table(new_t, old_t, name, depth)
	if not new_t or not old_t then return end
	
	local indent = get_indent(depth)
	debug_print(string.format("%s[Table更新] 开始处理table: %s (深度: %d)", indent, name, depth))
	
	-- 对某些关键函数不进行比对
	if CONFIG[new_t] or CONFIG[old_t] then 
		debug_print(string.format("%s[Table更新] 跳过保护对象: %s", indent, name))
		return 
	end
	
	-- 如果原值与当前值内存一致，值一样不进行对比
	if new_t == old_t then 
		debug_print(string.format("%s[Table更新] 相同对象，跳过: %s", indent, name))
		return 
	end
	
	local signature = tostring(old_t)..tostring(new_t)
	if visited_sig[signature] then 
		debug_print(string.format("%s[Table更新] 已访问过，跳过: %s", indent, name))
		return 
	end
	visited_sig[signature] = true
	debug_print(string.format("%s[Table更新] 标记为已访问: %s", indent, name))
	
	-- 遍历对比值
	local field_count = 0
	local updated_count = 0
	for field_name, value in pairs(new_t) do
		field_count = field_count + 1
		local old_value = old_t[field_name]
		debug_print(string.format("%s[Table更新] 处理字段: %s (类型: %s)", indent, field_name, type(value)))
		
		if type(value) == type(old_value) then
			if type(value) == 'function' then
				debug_print(string.format("%s[Table更新]  递归处理函数字段: %s", indent, field_name))
				update_func(value, old_value, field_name, depth + 1)
				old_t[field_name] = value
				updated_count = updated_count + 1
			elseif type(value) == 'table' then
				debug_print(string.format("%s[Table更新]  递归处理table字段: %s", indent, field_name))
				update_table(value, old_value, field_name, depth + 1)
				updated_count = updated_count + 1
			else
				debug_print(string.format("%s[Table更新]  相同类型字段，保持原值: %s", indent, field_name))
			end
		else
			debug_print(string.format("%s[Table更新]  类型不同，替换字段: %s (原类型: %s, 新类型: %s)", indent, field_name, type(old_value), type(value)))
			old_t[field_name] = value
			updated_count = updated_count + 1
		end
	end
	
	-- 遍历table的元表，进行对比
	local old_meta = debug.getmetatable(old_t)
	local new_meta = debug.getmetatable(new_t)
	if type(old_meta) == 'table' and type(new_meta) == 'table' then
		debug_print(string.format("%s[Table更新] 处理元表: %s", indent, name))
		update_table(new_meta, old_meta, safe_concat(name, "s Meta"), depth + 1)
	end
	
	debug_print(string.format("%s[Table更新] Table %s 处理完成 (字段数: %d, 更新数: %d)", indent, name, field_count, updated_count))
end

-- 对整个文件进行热更新
function M.hotfix_file(path)
	if not path then
		debug_print("文件路径为空")
		return false
	end

	debug_print(string.format("=== 开始热更新文件: %s ===", path))

	local module_info = package.loadinfo[path]
	if not module_info then
		debug_print(string.format("文件未加载: %s", path))
		return false
	end

	local oldmod = module_info.module_content
	if not oldmod then
		debug_print(string.format("模块内容为空: %s", path))
		return false
	end

	debug_print(string.format("模块类型: %s", type(oldmod)))

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
	
	-- 清空访问标记
	visited_sig = {}
	debug_print("已清空访问标记")
	
	-- 定义env的table，并为env设置_G访问权限
	local env = {}
	setmetatable(env, { __index = _G })
	debug_print("已创建环境表")
	
	-- 加载代码块
	local f, load_err = load(file_str, path, 't', env)
	if not f then
		debug_print(string.format("Failed to load file: %s, error: %s", path, load_err or "unknown error"))
		return false
	end
	
	debug_print("代码块加载成功")
	
	-- 执行代码块
	local ok, result = pcall(f)
	if not ok then
		debug_print(string.format("Failed to execute file: %s, error: %s", path, result or "unknown error"))
		return false
	end

	debug_print(string.format("代码块执行成功，返回值类型: %s", type(result)))

	-- 确定新的模块内容（文件返回值或环境表）
	local newmod = result ~= nil and result or env
	debug_print(string.format("新模块类型: %s", type(newmod)))
	
	-- 对比新旧模块内容
	local update_count = 0
	local total_fields = 0
	
	debug_print("=== 开始对比模块内容 ===")
	for name, new_value in pairs(newmod) do
		total_fields = total_fields + 1
		local old_value = oldmod[name]
		debug_print(string.format("[模块对比] 处理字段: %s (类型: %s)", name, type(new_value)))
		
		if not old_value then
			-- 新变量，直接添加
			debug_print(string.format("[模块对比]  新字段，直接添加: %s", name))
			oldmod[name] = new_value
			update_count = update_count + 1
		else
			if type(old_value) ~= type(new_value) then
				-- 类型不同，直接替换
				debug_print(string.format("[模块对比]  类型不同，直接替换: %s (原类型: %s, 新类型: %s)", name, type(old_value), type(new_value)))
				oldmod[name] = new_value
				update_count = update_count + 1
			elseif type(new_value) == 'function' then
				-- 函数，需要处理 upvalue
				debug_print(string.format("[模块对比]  递归处理函数: %s", name))
				update_func(new_value, old_value, name, 1)
				oldmod[name] = new_value
				update_count = update_count + 1
			elseif type(new_value) == 'table' then
				-- table，递归更新
				debug_print(string.format("[模块对比]  递归处理table: %s", name))
				update_table(new_value, old_value, name, 1)
				update_count = update_count + 1
			else
				-- 其他类型，直接替换
				debug_print(string.format("[模块对比]  其他类型，直接替换: %s", name))
				oldmod[name] = new_value
				update_count = update_count + 1
			end
		end
	end
	
	debug_print(string.format("=== 热更新完成: %s ===", path))
	debug_print(string.format("总字段数: %d, 更新字段数: %d", total_fields, update_count))
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
	
	local updated_count = 0
	local checked_count = 0
	
	debug_print("=== 开始检查热更新 ===")
	
	-- 遍历 loadinfo 中的所有文件
	local fileInfo
	for filename, module_info in pairs(package.loadinfo) do
		checked_count = checked_count + 1
		debug_print(string.format("[检查] 处理文件: %s", filename))
		
		fileInfo = lfs.attributes(filename)
		if fileInfo then
			if not module_info.loadtime then
				-- 没有 loadtime，获取并保存
				module_info.loadtime = fileInfo.modification
				debug_print(string.format("[检查] 已保存文件修改时间: %s -> %s", filename, os.date("%Y-%m-%d %H:%M:%S", fileInfo.modification)))
			else
				if module_info.loadtime ~= fileInfo.modification then
					debug_print(string.format("[检查] 文件 %s 修改时间发生变化: %s -> %s", filename, os.date("%Y-%m-%d %H:%M:%S", module_info.loadtime), os.date("%Y-%m-%d %H:%M:%S", fileInfo.modification)))

					-- 执行热更新
					local success = M.hotfix_file(filename)
					if success then
						updated_count = updated_count + 1
						debug_print(string.format("[检查] 热更新成功: %s", filename))
					else
						debug_print(string.format("[检查] 热更新失败: %s", filename))
					end

					-- 更新修改时间
					module_info.loadtime = fileInfo.modification
				else
					debug_print(string.format("[检查] 文件未变化: %s", filename))
				end
			end
		else
			debug_print(string.format("[检查] 无法获取文件信息: %s", filename))
		end
	end
	
	debug_print("=== 检查完成 ===")
	if updated_count > 0 then
		debug_print(string.format("批量热更新完成，检查了 %d 个文件，更新了 %d 个文件", checked_count, updated_count))
	else
		debug_print(string.format("没有文件需要热更新，检查了 %d 个文件", checked_count))
	end
	
	return updated_count > 0
end

return M


