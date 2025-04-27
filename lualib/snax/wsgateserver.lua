local skynet = require "skynet"
local netpack = require "skynet.netpack"
local socket = require "skynet.socket"
local websocket = require "http.websocket"

local wsgateserver = {}

local socketid	-- listen socket
local queue		-- message queue
local maxclient	-- max client
local client_number = 0
local CMD = setmetatable({}, { __gc = function() netpack.clear(queue) end })
local nodelay = false

local connection = {}
-- true : connected
-- nil : closed
-- false : close read

function wsgateserver.openclient(fd)
	-- if connection[fd] then
	-- 	socketdriver.start(fd)
	-- end
end

function wsgateserver.closeclient(id)
	local c = connection[id]
	if c ~= nil then
		connection[id] = nil
		websocket.close(id)
	end
end

function wsgateserver.start(handler)
    assert(handler.message)
	assert(handler.connect)

	-- local listen_context = {}

    --开启监听
    function CMD.open( source, conf )
		assert(not socketid)
		local address = conf.address or "0.0.0.0"
		local port = assert(conf.port)
		maxclient = conf.maxclient or 1024
		nodelay = conf.nodelay
		skynet.error(string.format("Listen websocket on %s:%d", address, port))
        socketid = socket.listen(address, port)
        -- listen_context.co = coroutine.running()
		-- listen_context.fd = socket
		-- skynet.wait(listen_context.co)
		conf.address = address
		conf.port = port

        socket.start(socketid, function(id, addr)
            print("有新的链接:"..id, addr)
            local ok, err = websocket.accept(id, handler, protocol, addr)
            if not ok then
                print(err)
            end
        end)
		if handler.open then
			return handler.open(source, conf)
		end
	end

    --关闭监听
    function CMD.close()
		assert(socketid)
		socketdriver.close(socketid)
	end

    local MSG = {}

    local function dispatch_msg(fd, msg, sz)
        print("MSG.data",fd, msg, sz)
		-- if connection[fd] then
		-- 	handler.message(fd, msg, sz)
		-- else
		-- 	skynet.error(string.format("Drop message from fd (%d) : %s", fd, netpack.tostring(msg,sz)))
		-- end
	end

    MSG.data = dispatch_msg

    local function dispatch_queue()
		local fd, msg, sz = netpack.pop(queue)
		if fd then
			-- may dispatch even the handler.message blocked
			-- If the handler.message never block, the queue should be empty, so only fork once and then exit.
			skynet.fork(dispatch_queue)
			dispatch_msg(fd, msg, sz)

			for fd, msg, sz in netpack.pop, queue do
				dispatch_msg(fd, msg, sz)
			end
		end
	end

	MSG.more = dispatch_queue

    function MSG.open(fd, msg)
        print("MSG.open",fd, msg)
	end

	function MSG.close(fd)
        print("MSG.close",fd)
	end

	function MSG.error(fd, msg)
        print("MSG.error",fd, msg)
	end

	function MSG.warning(fd, size)
        print("MSG.warning",fd, size)
	end

	function MSG.init(id, addr, port)
        print("MSG.init",id, addr, port)
	end











    local function init()
		skynet.dispatch("lua", function (_, address, cmd, ...)
            print("wsgateserver.lua",cmd, ...)
			local f = CMD[cmd]
			if f then
				skynet.ret(skynet.pack(f(address, ...)))
			else
				skynet.ret(skynet.pack(handler.command(cmd, address, ...)))
			end
		end)
	end

	if handler.embed then
		init()
	else
		skynet.start(init)
	end
end




return wsgateserver