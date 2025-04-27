local skynet = require "skynet"
local wsgateserver = require "snax.wsgateserver"
local websocket = require "http.websocket"
require "skynet.manager"


local wswatchdog
local connection = {}	-- fd -> connection : { fd , client, agent , ip, mode }

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
}

local handler = {}

function handler.open(source, conf)
    print("wsgate.handler.open",source, conf)
	wswatchdog = conf.watchdog or source
	return conf.address, conf.port
end

function handler.connect(id)
    print("wsgate.handler.connect",id)
    print("ws connect from: " .. tostring(id))
    local addr = websocket.addrinfo(id)
    local c = {
		fd = id,
		ip = addr,
	}
	connection[id] = c
	skynet.send(wswatchdog, "lua", "socket", "open", id, addr)
end

function handler.handshake(id, header, url)
    print("wsgate.handler.handshake",id, header, url)
    local addr = websocket.addrinfo(id)
    print("ws handshake from: " .. tostring(id), "url", url, "addr:", addr)
    print("----header-----")
    for k,v in pairs(header) do
        print(k,v)
    end
    print("--------------")

    
end


local function close_fd(fd)
	local c = connection[fd]
	if c then
		connection[fd] = nil
	end
end

function handler.message(id, msg, msg_type)
    print("wsgate.handler.message",id, msg, msg_type)
    assert(msg_type == "binary" or msg_type == "text")
    print("ws message:"..msg)
    
    skynet.send(wswatchdog, "lua", "socket", "data", id, msg)

    --先给返回
    websocket.write(id, msg)
end

function handler.ping(id)
    print("wsgate.handler.ping",id)
    print("ws ping from: " .. tostring(id) .. "\n")
end

function handler.pong(id)
    print("wsgate.handler.pong",id)
    print("ws pong from: " .. tostring(id))
end

function handler.close(id, code, reason)
    print("wsgate.handler.close",id, code, reason)
    print("ws close from: " .. tostring(id), code, reason)
end

function handler.error(id)
    print("wsgate.handler.error",id)
    print("ws error from: " .. tostring(id))
end

local CMD = {}

-- function CMD.forward(source, fd, client, address)
-- 	local c = assert(connection[fd])
-- 	unforward(c)
-- 	c.client = client or 0
-- 	c.agent = address or source
-- 	gateserver.openclient(fd)
-- end

-- function CMD.accept(source, fd)
-- 	local c = assert(connection[fd])
-- 	unforward(c)
-- 	gateserver.openclient(fd)
-- end

function CMD.kick(source, fd)
	wsgateserver.closeclient(fd)
end

function handler.command(cmd, source, ...)
	print(string.format("wsgate.handler.command:"..cmd))
	local f = assert(CMD[cmd])
	return f(source, ...)
end

wsgateserver.start(handler)