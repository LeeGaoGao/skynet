-- Lua热更新实现
-- 用途：在生产环境中快速修复Bug，无需停机维护
-- 原理：利用_ENV环境，在加载时把数据加载到_ENV下，然后通过对比方式修改_G底下的值

local lfs = require "lfs"

local M = {}

local print_flag = false

local function debug_print(str)
	if print_flag then
		print(str)
	end
end

-- 对整个文件进行热更新
function M.hotfix_file(path)
	if not path then
		debug_print("文件路径为空")
		return false
	end

	local module_info = package.loaded[path]
	if not module_info then
		debug_print(string.format("文件未加载: %s", path))
		return false
	end

	if type(module_info) ~= "table" then
		debug_print(string.format("文件不支持热更新: %s(返回值不是 table 类型)", path))
		return false
	end

	if not module_info.__PATH__ then
		debug_print(string.format("文件不支持热更新: %s(没有 __PATH__ 字段)", path))
		return false
	end

	local old_env = module_info.__ENV__
	if not old_env then
		debug_print(string.format("文件代码环境不存在: %s(没有 __ENV__ 字段)", path))
		return false
	end

	local file_str
	local fp = io.open(module_info.__PATH__, "r")
	if not fp then
		debug_print(string.format("无法打开文件: %s", module_info.__PATH__))
		return false
	end
	
	local file_str = fp:read('*all')
	fp:close()
	
	if not file_str then
		debug_print(string.format("文件内容为空: %s", module_info.__PATH__))
		return false
	end
	
	debug_print(string.format("文件大小: %d 字节", #file_str))
	
	-- 加载代码块
	local f, load_err = load(file_str, module_info.__PATH__, 't', old_env)
	if not f then
		debug_print(string.format("文件加载失败: %s, error: %s", module_info.__PATH__, load_err or "unknown error"))
		return false
	end
		
	-- 执行代码块
	local ok, result = pcall(f)
	if not ok then
		debug_print(string.format("文件执行失败: %s, error: %s", module_info.__PATH__, result or "unknown error"))
		return false
	end

	module_info.__RESULT__ = result
	
	debug_print(string.format("=== 热更新完成: %s ===", module_info.__PATH__))
	return true
end

-- 检查并更新 loadinfo 中的 loadtime
function M.CheckHotFix(not_print)
	-- 是否打印日志
	print_flag = not not_print

	debug_print("=== 开始检查热更新 ===")
	
	-- 遍历 loadinfo 中的所有文件
	local fileInfo
	for name, module_info in pairs(package.loaded) do
		if module_info.__PATH__ then
			debug_print(string.format("[检查] 处理文件: %s", module_info.__PATH__))
			fileInfo = lfs.attributes(module_info.__PATH__)
			if fileInfo and module_info.__LOADTIME__ then
				if module_info.__LOADTIME__ ~= fileInfo.modification then
					debug_print(string.format("[检查] 文件 %s 修改时间发生变化: %s -> %s", module_info.__PATH__, os.date("%Y-%m-%d %H:%M:%S", module_info.__LOADTIME__), os.date("%Y-%m-%d %H:%M:%S", fileInfo.modification)))

					module_info.__LOADTIME__ = fileInfo.modification

					-- 执行热更新
					local success = M.hotfix_file(name)
					if success then
						debug_print(string.format("[检查] 热更新成功: %s",  module_info.__PATH__))
					else
						debug_print(string.format("[检查] 热更新失败: %s",  module_info.__PATH__))
					end
				end
			else
				debug_print(string.format("[检查] 无法获取文件信息: %s",  module_info.__PATH__))
			end
		end
	end
end

return M




--[[
全局 table
	以新表为准,保存数据的模块不允许热更, 否则会导致数据丢失








]]