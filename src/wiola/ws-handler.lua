--
-- Project: wiola
-- User: Konstantin Burkalev
-- Date: 16.03.14
--
local wsServer = require "resty.websocket.server"
local wiola = require "wiola"
local config = require("wiola.config").config()
local webSocket, wampServer, ok, err, bytes, pingCo
local ignoreAbort = false

webSocket, err = wsServer:new({
    timeout = config.socketTimeout,
    max_payload_len = config.maxPayloadLen
})

if not webSocket then
    ngx.log(ngx.ERR, "Failed to create new websocket: ", err)
    return ngx.exit(444)
end

ngx.log(ngx.DEBUG, "Created websocket")

wampServer, err = wiola:new()
if not wampServer then
    ngx.log(ngx.DEBUG, "Failed to create a wiola instance: ", err)
    return ngx.exit(444)
end

local sessionId, dataType = wampServer:addConnection(ngx.var.connection, ngx.header["Sec-WebSocket-Protocol"])
ngx.log(ngx.DEBUG, "Adding connection to list. Conn Id: ", ngx.var.connection)
ngx.log(ngx.DEBUG, "Session Id: ", sessionId, " selected protocol: ", ngx.header["Sec-WebSocket-Protocol"])

local function removeConnection(_, sessId, exitCode)

    ngx.log(ngx.DEBUG, "Cleaning up session: ", sessId)

    local wconfig = require("wiola.config").config()
    local store = require('wiola.stores.' .. config.store)

    ok, err = store:init(wconfig)
    if not ok then
        ngx.log(ngx.DEBUG, "Can not init datastore!", err)
    else
        store:removeSession(sessId)
        ngx.log(ngx.DEBUG, "Session data successfully removed!")
    end

    ngx.exit(exitCode)
end

local function removeConnectionWrapper()
    if ignoreAbort then
        return
    end
    ngx.log(ngx.DEBUG, "client on_abort removeConnection callback fired!")
    removeConnection(true, sessionId, 444)
end

ok, err = ngx.on_abort(removeConnectionWrapper)
if not ok then
    ngx.log(ngx.ERR, "failed to register the on_abort callback: ", err)
    ngx.exit(444)
end

if config.wsPingInterval > 0 then
    local pinger = function (period)
        local bytes, err
        coroutine.yield()

        while true do
            ngx.log(ngx.DEBUG, "Pinging client...")
            bytes, err = webSocket:send_ping()
            if not bytes then
                ngx.log(ngx.ERR, "Failed to send ping: ", err)
                ngx.timer.at(0, removeConnection, sessionId, 444)
            end
            ngx.sleep(period)
        end
    end

    pingCo = ngx.thread.spawn(pinger, config.wsPingInterval / 1000)
end

while true do
--    ngx.log(ngx.DEBUG, "Started handler loop!")
    local cliData, data, typ, hflags

    hflags = wampServer:getHandlerFlags(sessionId)
    if hflags ~= nil then
        if hflags.sendLast == true then
            cliData = wampServer:getPendingData(sessionId, true)

            if dataType == 'binary' then
                bytes, err = webSocket:send_binary(cliData)
            else
                bytes, err = webSocket:send_text(cliData)
            end

            if not bytes then
                ngx.log(ngx.ERR, "Failed to send data: ", err)
            end
        end

        if hflags.close == true then
            ngx.log(ngx.DEBUG, "Got close connection flag for session")
            ngx.timer.at(0, removeConnection, sessionId, 444)
        end
    end

--    ngx.log(ngx.DEBUG, "Checking data for client...")
    cliData = wampServer:getPendingData(sessionId)

    while cliData ~= ngx.null do
        ngx.log(ngx.DEBUG, "Got data for client. DataType is ", dataType, ". Data: ", cliData, ". Sending...")
        if dataType == 'binary' then
            bytes, err = webSocket:send_binary(cliData)
        else
            bytes, err = webSocket:send_text(cliData)
        end

        if not bytes then
            ngx.log(ngx.ERR, "Failed to send data: ", err)
        end

        cliData = wampServer:getPendingData(sessionId)
    end

    if webSocket.fatal then
        ngx.log(ngx.ERR, "Failed to receive frame: ", err)
        ngx.timer.at(0, removeConnection, sessionId, 444)
    end

    data, typ = webSocket:recv_frame()
    --ngx.log(ngx.DEBUG, "Received WS Frame. Type is ", typ)

    if typ == "close" then

        ngx.log(ngx.DEBUG, "Normal closing websocket. SID: ", ngx.var.connection)
        bytes, err = webSocket:send_close(1000, "Closing connection")
            if not bytes then
                ngx.log(ngx.ERR, "Failed to send the close frame: ", err)
                return
            end
        webSocket:send_close()
        ignoreAbort = true
        if pingCo then
            ngx.thread.kill(pingCo)
        end
        ngx.timer.at(0, removeConnection, sessionId, 200)
        break

    elseif typ == "ping" then

        bytes, err = webSocket:send_pong()
        if not bytes then
            ngx.log(ngx.ERR, "Failed to send pong: ", err)
            ngx.timer.at(0, removeConnection, sessionId, 444)
        end

--    elseif typ == "pong" then

--        ngx.log(ngx.DEBUG, "client ponged")

    elseif typ == "text" then -- Received something texty

        ngx.log(ngx.DEBUG, "Received text data: ", data)
        wampServer:receiveData(sessionId, data)

    elseif typ == "binary" then -- Received something binary

        ngx.log(ngx.DEBUG, "Received binary data")
        wampServer:receiveData(sessionId, data)

    end

--    ngx.log(ngx.DEBUG, "Finished handler loop!")
end
