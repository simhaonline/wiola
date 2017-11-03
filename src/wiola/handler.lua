--
-- Project: wiola
-- User: Konstantin Burkalev
-- Date: 16.03.14
--
local wsServer = require "resty.websocket.server"
local wiola = require "wiola"

local webSocket, err = wsServer:new({
    timeout = tonumber(ngx.var.wiola_socket_timeout, 10) or 100,
    max_payload_len = tonumber(ngx.var.wiola_max_payload_len, 10) or 65535
})

if not webSocket then
    ngx.log(ngx.ERR, "Failed to create new websocket: ", err)
    return ngx.exit(444)
end

ngx.log(ngx.DEBUG, "Created websocket")

local wampServer, err = wiola:new()
if not wampServer then
    ngx.log(ngx.DEBUG, "Failed to create a wiola instance: ", err)
    return ngx.exit(444)
end

local sessionId, dataType = wampServer:addConnection(ngx.var.connection, ngx.header["Sec-WebSocket-Protocol"])
ngx.log(ngx.DEBUG, "Adding connection to list. Conn Id: ", ngx.var.connection)
ngx.log(ngx.DEBUG, "Session Id: ", sessionId, " selected protocol: ", ngx.header["Sec-WebSocket-Protocol"])

local function removeConnection(premature, sessionId)

    ngx.log(ngx.DEBUG, "Cleaning up session: ", sessionId)

    local config = require("wiola.config").config()
    local store = require('wiola.stores.' .. config.store)

    local ok, err = store:init(config.storeConfig)
    if not ok then
        ngx.log(ngx.DEBUG, "Can not init datastore!", err)
    else
        store:removeSession(sessionId)
        ngx.log(ngx.DEBUG, "Session data successfully removed!")
    end
end

local function removeConnectionWrapper()
    ngx.log(ngx.DEBUG, "client on_abort removeConnection callback fired!")
    removeConnection(true, sessionId)
end

local ok, err = ngx.on_abort(removeConnectionWrapper)
if not ok then
    ngx.log(ngx.ERR, "failed to register the on_abort callback: ", err)
    ngx.exit(444)
end

while true do
--    ngx.log(ngx.DEBUG, "Started handler loop!")

--    ngx.log(ngx.DEBUG, "Checking data for client...")
    local cliData, cliErr = wampServer:getPendingData(sessionId)

    while cliData ~= ngx.null do
        ngx.log(ngx.DEBUG, "Got data for client. DataType is ", dataType, ". Sending...")
        local bytes, err
        if dataType == 'binary' then
            bytes, err = webSocket:send_binary(cliData)
        else
            bytes, err = webSocket:send_text(cliData)
        end

        if not bytes then
            ngx.log(ngx.ERR, "Failed to send data: ", err)
        end

        cliData, cliErr = wampServer:getPendingData(sessionId)
    end

    if webSocket.fatal then
        ngx.log(ngx.ERR, "Failed to receive frame: ", err)
        ngx.timer.at(0, removeConnection, sessionId)
        return ngx.exit(444)
    end

    local data, typ, err = webSocket:recv_frame()

    if not data then

        local bytes, err = webSocket:send_ping()
        if not bytes then
            ngx.log(ngx.ERR, "Failed to send ping: ", err)
            ngx.timer.at(0, removeConnection, sessionId)
            return ngx.exit(444)
        end

    elseif typ == "close" then

        ngx.log(ngx.DEBUG, "Normal closing websocket. SID: ", ngx.var.connection)
        local bytes, err = webSocket:send_close(1000, "Closing connection")
            if not bytes then
                ngx.log(ngx.ERR, "Failed to send the close frame: ", err)
                return
            end
        ngx.timer.at(0, removeConnection, sessionId)
        webSocket:send_close()
        break

    elseif typ == "ping" then

        local bytes, err = webSocket:send_pong()
        if not bytes then
            ngx.log(ngx.ERR, "Failed to send pong: ", err)
            ngx.timer.at(0, removeConnection, sessionId)
            return ngx.exit(444)
        end

    elseif typ == "pong" then

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
