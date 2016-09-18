local mg     = require "moongen"
local memory = require "memory"
local device = require "device"
local stats  = require "stats"
local log    = require "log"
local timer  = require "timer"
local ffi    = require "ffi"

function configure(parser)
	parser:description([[
		Sends a lot of random background traffic from/to 10.0.0.0/16 on UDP ports 1000-10000.
		One of the flows sends a single packet to destination port 60000 after a configurable delay with the string "EXAMPLE" in the payload.
		Use this trigger to retroactively dump all activity of this whole flow while ignoring all of the background traffic:
		"udp dst 60000"
		Alternatively, you can use filter-examples/trigger-payload.lua in FlowScope as a code trigger.
	]])
    parser:argument("dev", "Devices to use."):args("+"):convert(tonumber)
	parser:option("-r --rate", "Background traffic in Mbit/s."):default(10000):convert(tonumber)
	parser:option("-t --trigger-delay", "Delay in seconds after which the trigger packet is injected."):default(5):convert(tonumber):target("triggerDelay")
	parser:option("-d --trigger-device", "Device that sends the trigger flow, defaults to the first device."):convert(tonumber):target("triggerDev")
	parser:option("-s --size", "Packet size."):default(124):convert(tonumber)
end

function master(args)
	if not args.triggerDev then
		args.triggerDev = args.dev[1]
	end
	for i, dev in ipairs(args.dev) do
		args.dev[i] = device.config{port = dev, txQueues = args.triggerDev == dev and 2 or 1}
		if dev == args.triggerDev then
			args.triggerDev = args.dev[i]
		end
	end
	device.waitForLinks()
	stats.startStatsTask{txDevices = args.dev}
	for i, dev in ipairs(args.dev) do
		mg.startTask("loadSlave", dev:getTxQueue(0), args.size)
	end
	mg.startSharedTask("triggerTraffic", args.triggerDev:getTxQueue(1), args.size, args.triggerDelay)
	mg.waitForTasks()
end

function loadSlave(queue, size)
	local mempool = memory.createMemPool(function(buf)
		buf:getUdpPacket():fill{pktLength = size}
	end)
	local bufs = mempool:bufArray()
	local baseIP = parseIPAddress("10.0.0.2")
	while mg.running() do
		bufs:alloc(size)
		for i, buf in ipairs(bufs) do
			local pkt = buf:getUdpPacket()
			pkt.ip4.src:set(baseIP + math.random(0, 2^15))
			pkt.ip4.dst:set(baseIP + math.random(0, 2^15))
			pkt.udp:setSrcPort(math.random(1000, 10000))
			pkt.udp:setDstPort(math.random(1000, 10000))
		end
		bufs:offloadUdpChecksums()
		queue:send(bufs)
	end
end

function triggerTraffic(queue, size, timeout)
	local mempool = memory.createMemPool(function(buf)
		buf:getUdpPacket():fill{
			ip4Src = "10.0.0.1",
			pktLength = size
		}
	end)
	local bufs = mempool:bufArray(1)
	local baseIP = parseIPAddress("10.0.0.2")
	local rateLimiter = timer:new(0.1)
	local magicPacketDelay = timer:new(timeout)
	local ctr = 1
	while mg.running() do
		bufs:alloc(size)
		for i, buf in ipairs(bufs) do
			local pkt = buf:getUdpPacket()
			pkt.ip4.dst:set(baseIP + math.random(0, 2^15))
			pkt.udp:setSrcPort(ctr)
			if magicPacketDelay:expired() then
				pkt.udp:setDstPort(60000)
				ffi.copy(pkt.payload.uint8, "EXAMPLExx")
				magicPacketDelay:reset(math.huge) -- just one trigger packet, but the flow continues
				log:info("Sending trigger packet")
			else
				pkt.udp:setDstPort(math.random(1000, 10000))
				ffi.copy(pkt.payload.uint8, "xxxxxxxx")
			end
			ctr = ctr + 1
		end
		bufs:offloadUdpChecksums()
		queue:send(bufs)
		rateLimiter:wait()
		rateLimiter:reset()
	end
end

