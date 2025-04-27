local skynet = require "skynet"

local CMD = {}
local SOCKET = {}
local wsgate
local agents = {}
local agentmgr

function SOCKET.open(id, addr)
	skynet.error("New ws client from : " .. addr,id)
	-- agent[fd] = skynet.newservice("agent")
	-- skynet.call(agent[fd], "lua", "start", { gate = wsgate, client = fd, watchdog = skynet.self() })
    -- local isok, agent = pcall(skynet.call, agentmgr, "lua", "start", id, addr)
    -- if isok then
    --     agents[id] = agent
    -- else
    --     print("向 agent 发送用户连接错误")
    -- end
end

local function close_agent(id)
	-- local agent = agents[id]
	-- agents[id] = nil
	-- if agent then
	-- 	skynet.call(wsgate, "lua", "kick", id)
	-- 	-- disconnect never return
	-- 	skynet.send(agent, "lua", "disconnect", )
	-- end
end

function SOCKET.close(fd)
	print("socket close",fd)
	--close_agent(fd)
end

function SOCKET.error(fd, msg)
	print("socket error",fd, msg)
	--close_agent(fd)
end

function SOCKET.warning(fd, size)
	-- size K bytes havn't send out in fd
	print("socket warning", fd, size)
end

function SOCKET.data(fd, msg)
    print("socket data",fd, msg)
end

function CMD.start(conf)
	return skynet.call(wsgate, "lua", "open" , conf)
end

function CMD.close(fd)
	close_agent(fd)
end

function CMD.agentmgr(addr)
    agentmgr = addr
end

skynet.start(function()
	skynet.dispatch("lua", function(session, source, cmd, subcmd, ...)
		if cmd == "socket" then
			local f = SOCKET[subcmd]
			f(...)
			-- socket api don't need return
		else
			local f = assert(CMD[cmd])
			skynet.ret(skynet.pack(f(subcmd, ...)))
		end
	end)

	wsgate = skynet.newservice("wsgate")
end)
