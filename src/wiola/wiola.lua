--
-- Project: wiola
-- User: Konstantin Burkalev
-- Date: 16.03.14
--

local getdump = require("debug.vardump").getdump

local _M = {
    _VERSION = '0.8.0',
}

_M.__index = _M

setmetatable(_M, {
    __call = function(cls, ...)
        return cls.new(...)
    end
})

local wamp_features = {
    agent = "wiola/Lua v" .. _M._VERSION,
    roles = {
        broker = {
            features = {
                subscriber_blackwhite_listing = true,
                publisher_exclusion = true,
                publisher_identification = true
            }
        },
        dealer = {
            features = {
                caller_identification = true,
                progressive_call_results = true,
                call_canceling = true,
                call_timeout = true
            }
        }
    }
}

local config = require("wiola.config").config()
local serializers = {
    json = require('wiola.serializers.json_serializer'),
    msgpack = require('wiola.serializers.msgpack_serializer')
}
local store = require('wiola.stores.' .. config.store)

local WAMP_MSG_SPEC = {
    HELLO = 1,
    WELCOME = 2,
    ABORT = 3,
    CHALLENGE = 4,
    AUTHENTICATE = 5,
    GOODBYE = 6,
    ERROR = 8,
    PUBLISH = 16,
    PUBLISHED = 17,
    SUBSCRIBE = 32,
    SUBSCRIBED = 33,
    UNSUBSCRIBE = 34,
    UNSUBSCRIBED = 35,
    EVENT = 36,
    CALL = 48,
    CANCEL = 49,
    RESULT = 50,
    REGISTER = 64,
    REGISTERED = 65,
    UNREGISTER = 66,
    UNREGISTERED = 67,
    INVOCATION = 68,
    INTERRUPT = 69,
    YIELD = 70
}

-- Check for a value in table
local has = function(tab, val)
    for index, value in ipairs(tab) do
        if value == val then
            return true
        end
    end

    return false
end

--
-- Create a new instance
--
-- returns wiola instance
--
function _M.new()
    local self = setmetatable({}, _M)
    local ok, err = store:init(config.storeConfig)
    if not ok then
        return ok, err
    end

    return self

end

-- Generate a random string
function _M:_randomString(length)
    local str = "";
    local time = self.redis:time()

    --    math.randomseed( os.time() ) -- Precision - only seconds, which is not acceptable
    math.randomseed(time[1] * 1000000 + time[2])

    for i = 1, length do
        str = str .. string.char(math.random(32, 126));
    end
    return str;
end

-- Validate uri for WAMP requirements
function _M:_validateURI(uri)
    local m, err = ngx.re.match(uri, "^([0-9a-zA-Z_]{2,}\\.)*([0-9a-zA-Z_]{2,})$")
    ngx.log(ngx.DEBUG, 'Validating URI: ', uri, '. Found match? ', m == nil, ', error: ', err)
    if not m or string.find(uri, 'wamp') == 1 then
        return false
    else
        return true
    end
end

--
-- Add connection to wiola
--
-- sid - nginx session connection ID
-- wampProto - chosen WAMP protocol
--
-- returns WAMP session registration ID, connection data type
--
function _M:addConnection(sid, wampProto)
    local regId = store:getRegId()
    local wProto, dataType, session

    if wampProto == nil or wampProto == "" then
        wampProto = 'wamp.2.json' -- Setting default protocol for encoding/decodig use
    end

    if wampProto == 'wamp.2.msgpack' then
        dataType = 'binary'
    else
        dataType = 'text'
    end

    store:addSession(regId, {
        connId = sid,
        sessId = regId,
        isWampEstablished = 0,
        --        realm = nil,
        --        wamp_features = nil,
        wamp_protocol = wampProto,
        encoding = string.match(wampProto, '.*%.([^.]+)$'),
        dataType = dataType
    })

    return regId, dataType
end

-- Prepare data for sending to client
function _M:_putData(session, data)
    local dataObj = serializers[session.encoding].encode(data)

    ngx.log(ngx.DEBUG, "Preparing data for client: ", dataObj)
    store:putData(session, dataObj)
    ngx.log(ngx.DEBUG, "Pushed data for client into redis")
end

-- Publish event to sessions
function _M:_publishEvent(sessRegIds, subId, pubId, details, args, argsKW)
    -- WAMP SPEC: [EVENT, SUBSCRIBED.Subscription|id, PUBLISHED.Publication|id, Details|dict]
    -- WAMP SPEC: [EVENT, SUBSCRIBED.Subscription|id, PUBLISHED.Publication|id, Details|dict, PUBLISH.Arguments|list]
    -- WAMP SPEC: [EVENT, SUBSCRIBED.Subscription|id, PUBLISHED.Publication|id, Details|dict, PUBLISH.Arguments|list, PUBLISH.ArgumentKw|dict]

    ngx.log(ngx.DEBUG, "Publish events, sessions to notify: ", #sessRegIds)

    local data
    if not args and not argsKW then
        data = { WAMP_MSG_SPEC.EVENT, subId, pubId, details }
    elseif args and not argsKW then
        data = { WAMP_MSG_SPEC.EVENT, subId, pubId, details, args }
    else
        data = { WAMP_MSG_SPEC.EVENT, subId, pubId, details, args, argsKW }
    end

    for k, v in ipairs(sessRegIds) do
        local session = store:getSession(v)
        self:_putData(session, data)
    end
end

--
-- Receive data from client
--
-- regId - WAMP session registration ID
-- data - data, received through websocket
--
function _M:receiveData(regId, data)
    local session = store:getSession(regId)

    local dataObj = serializers[session.encoding].decode(data)

    ngx.log(ngx.DEBUG, "Cli regId: ", regId, " Received data. WAMP msg Id: ", dataObj[1])

    -- Analyze WAMP message ID received
    if dataObj[1] == WAMP_MSG_SPEC.HELLO then -- WAMP SPEC: [HELLO, Realm|uri, Details|dict]
        if session.isWampEstablished == 1 then
            -- Protocol error: received second hello message - aborting
            -- WAMP SPEC: [GOODBYE, Details|dict, Reason|uri]
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        else
            local realm = dataObj[2]
            if self:_validateURI(realm) then

                if config.wampCRA.authType ~= "none" then

                    if dataObj[3].authmethods and has(dataObj[3].authmethods, "wampcra") and dataObj[3].authid then

                        local challenge, challengeString, signature

                        store:changeChallenge(regId, { realm = realm, wampFeatures = serializers.json.encode(dataObj[3]) })

                        if config.wampCRA.authType == "static" then

                            if config.wampCRA.staticCredentials[dataObj[3].authid] then

                                challenge = {
                                    authid = dataObj[3].authid,
                                    authrole = config.wampCRA.staticCredentials[dataObj[3].authid].authrole,
                                    authmethod = "wampcra",
                                    authprovider = "wiolaStaticAuth",
                                    nonce = self:_randomString(16),
                                    timestamp = os.date("!%FT%TZ"), -- without ms. "!%FT%T.%LZ"
                                    session = regId
                                }

                                challengeString = serializers.json.encode(challenge)

                                local hmac = require "resty.hmac"
                                local hm, err = hmac:new(config.wampCRA.staticCredentials[dataObj[3].authid].secret)

                                signature, err = hm:generate_signature("sha256", challengeString)

                                if signature then

                                    challenge.signature = signature
                                    store:changeChallenge(regId, challenge)

                                    -- WAMP SPEC: [CHALLENGE, AuthMethod|string, Extra|dict]
                                    self:_putData(session, { WAMP_MSG_SPEC.CHALLENGE, "wampcra", { challenge = challengeString } })

                                else
                                    -- WAMP SPEC: [ABORT, Details|dict, Reason|uri]
                                    self:_putData(session, { WAMP_MSG_SPEC.ABORT, setmetatable({}, { __jsontype = 'object' }), "wamp.error.authorization_failed" })
                                end
                            else
                                -- WAMP SPEC: [ABORT, Details|dict, Reason|uri]
                                self:_putData(session, { WAMP_MSG_SPEC.ABORT, setmetatable({}, { __jsontype = 'object' }), "wamp.error.authorization_failed" })
                            end

                        elseif config.wampCRA.authType == "dynamic" then

                            challenge = config.wampCRA.challengeCallback(regId, dataObj[3].authid)

                            -- WAMP SPEC: [CHALLENGE, AuthMethod|string, Extra|dict]
                            self:_putData(session, { WAMP_MSG_SPEC.CHALLENGE, "wampcra", { challenge = challenge } })
                        end
                    else
                        -- WAMP SPEC: [ABORT, Details|dict, Reason|uri]
                        self:_putData(session, { WAMP_MSG_SPEC.ABORT, setmetatable({}, { __jsontype = 'object' }), "wamp.error.authorization_failed" })
                    end
                else

                    session.isWampEstablished = 1
                    session.realm = realm
                    session.wampFeatures = serializers.json.encode(dataObj[3])
                    store:changeSession(regId, session)
                    store:addSessionToRealm(regId, realm)

                    -- WAMP SPEC: [WELCOME, Session|id, Details|dict]
                    self:_putData(session, { WAMP_MSG_SPEC.WELCOME, regId, wamp_features })
                end
            else
                -- WAMP SPEC: [ABORT, Details|dict, Reason|uri]
                self:_putData(session, { WAMP_MSG_SPEC.ABORT, setmetatable({}, { __jsontype = 'object' }), "wamp.error.invalid_uri" })
            end
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.AUTHENTICATE then -- WAMP SPEC: [AUTHENTICATE, Signature|string, Extra|dict]

        if session.isWampEstablished == 1 then
            -- Protocol error: received second message - aborting
            -- WAMP SPEC: [GOODBYE, Details|dict, Reason|uri]
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        else

            local challenge = store:getChallenge(regId)
            local authInfo

            if config.wampCRA.authType == "static" then

                if dataObj[2] == challenge.signature then
                    authInfo = {
                        authid = challenge.authid,
                        authrole = challenge.authrole,
                        authmethod = challenge.authmethod,
                        authprovider = challenge.authprovider
                    }
                end

            elseif config.wampCRA.authType == "dynamic" then
                authInfo = config.wampCRA.authCallback(regId, dataObj[2])
            end

            if authInfo then

                session.isWampEstablished = 1
                session.realm = challenge.realm
                session.wampFeatures = challenge.wampFeatures
                store:changeSession(regId, session)
                store:addSessionToRealm(regId, challenge.realm)

                local details = wamp_features
                details.authid = authInfo.authid
                details.authrole = authInfo.authrole
                details.authmethod = authInfo.authmethod
                details.authprovider = authInfo.authprovider

                -- WAMP SPEC: [WELCOME, Session|id, Details|dict]
                self:_putData(session, { WAMP_MSG_SPEC.WELCOME, regId, details })

            else
                -- WAMP SPEC: [ABORT, Details|dict, Reason|uri]
                self:_putData(session, { WAMP_MSG_SPEC.ABORT, setmetatable({}, { __jsontype = 'object' }), "wamp.error.authorization_failed" })
            end
        end

        -- Clean up Challenge data in any case
        store:removeChallenge(regId)

    elseif dataObj[1] == WAMP_MSG_SPEC.ABORT then -- WAMP SPEC: [ABORT, Details|dict, Reason|uri]
        -- No response is expected
    elseif dataObj[1] == WAMP_MSG_SPEC.GOODBYE then -- WAMP SPEC: [GOODBYE, Details|dict, Reason|uri]
        if session.isWampEstablished == 1 then
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.goodbye_and_out" })
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.ERROR then
        -- WAMP SPEC: [ERROR, REQUEST.Type|int, REQUEST.Request|id, Details|dict, Error|uri]
        -- WAMP SPEC: [ERROR, REQUEST.Type|int, REQUEST.Request|id, Details|dict, Error|uri, Arguments|list]
        -- WAMP SPEC: [ERROR, REQUEST.Type|int, REQUEST.Request|id, Details|dict, Error|uri, Arguments|list, ArgumentsKw|dict]
        if session.isWampEstablished == 1 then
            if dataObj[2] == WAMP_MSG_SPEC.INVOCATION then
                -- WAMP SPEC: [ERROR, INVOCATION, INVOCATION.Request|id, Details|dict, Error|uri]
                -- WAMP SPEC: [ERROR, INVOCATION, INVOCATION.Request|id, Details|dict, Error|uri, Arguments|list]
                -- WAMP SPEC: [ERROR, INVOCATION, INVOCATION.Request|id, Details|dict, Error|uri, Arguments|list, ArgumentsKw|dict]

                local invoc = store:getInvocation(dataObj[3])
                local callerSess = store:getSession(invoc.callerSesId)

                if #dataObj == 6 then
                    -- WAMP SPEC: [ERROR, CALL, CALL.Request|id, Details|dict, Error|uri, Arguments|list]
                    self:_putData(callerSess, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.CALL, invoc.CallReqId, setmetatable({}, { __jsontype = 'object' }), dataObj[5], dataObj[6] })
                elseif #dataObj == 7 then
                    -- WAMP SPEC: [ERROR, CALL, CALL.Request|id, Details|dict, Error|uri, Arguments|list, ArgumentsKw|dict]
                    self:_putData(callerSess, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.CALL, invoc.CallReqId, setmetatable({}, { __jsontype = 'object' }), dataObj[5], dataObj[6], dataObj[7] })
                else
                    -- WAMP SPEC: [ERROR, CALL, CALL.Request|id, Details|dict, Error|uri]
                    self:_putData(callerSess, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.CALL, invoc.CallReqId, setmetatable({}, { __jsontype = 'object' }), dataObj[5] })
                end

                store:removeInvocation(dataObj[3])
            end
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.PUBLISH then
        -- WAMP SPEC: [PUBLISH, Request|id, Options|dict, Topic|uri]
        -- WAMP SPEC: [PUBLISH, Request|id, Options|dict, Topic|uri, Arguments|list]
        -- WAMP SPEC: [PUBLISH, Request|id, Options|dict, Topic|uri, Arguments|list, ArgumentsKw|dict]
        if session.isWampEstablished == 1 then
            if self:_validateURI(dataObj[4]) then
                local pubId = store:getRegId()
                local recipients = store:getEventRecipients(session.realm, dataObj[4], regId, dataObj[3])
                local details = {}

                if dataObj[3].disclose_me ~= nil and dataObj[3].disclose_me == true then
                    details.publisher = regId
                end

                local subId = store:getSubscriptionId(session.realm, dataObj[4])
                if subId then
                    ngx.log(ngx.DEBUG, "Publishing event to subscription ID: ", ('%d'):format(subId))
                    self:_publishEvent(recipients, subId, pubId, details, dataObj[5], dataObj[6])

                    if dataObj[3].acknowledge and dataObj[3].acknowledge == true then
                        -- WAMP SPEC: [PUBLISHED, PUBLISH.Request|id, Publication|id]
                        self:_putData(session, { WAMP_MSG_SPEC.PUBLISHED, dataObj[2], pubId })
                    end
                end
            else
                self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.PUBLISH, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.invalid_uri" })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.SUBSCRIBE then -- WAMP SPEC: [SUBSCRIBE, Request|id, Options|dict, Topic|uri]
        if session.isWampEstablished == 1 then
            if self:_validateURI(dataObj[4]) then
                local subscriptionId = store:subscribeSession(session.realm, dataObj[4], regId)

                -- WAMP SPEC: [SUBSCRIBED, SUBSCRIBE.Request|id, Subscription|id]
                self:_putData(session, { WAMP_MSG_SPEC.SUBSCRIBED, dataObj[2], subscriptionId })
            else
                self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.SUBSCRIBE, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.invalid_uri" })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.UNSUBSCRIBE then -- WAMP SPEC: [UNSUBSCRIBE, Request|id, SUBSCRIBED.Subscription|id]
        if session.isWampEstablished == 1 then
            local isSesSubscrbd = store:unsubscribeSession(session.realm, dataObj[3], regId)
            if isSesSubscrbd ~= ngx.null then
                -- WAMP SPEC: [UNSUBSCRIBED, UNSUBSCRIBE.Request|id]
                self:_putData(session, { WAMP_MSG_SPEC.UNSUBSCRIBED, dataObj[2] })
            else
                self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.UNSUBSCRIBE, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.no_such_subscription" })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.CALL then
        -- WAMP SPEC: [CALL, Request|id, Options|dict, Procedure|uri]
        -- WAMP SPEC: [CALL, Request|id, Options|dict, Procedure|uri, Arguments|list]
        -- WAMP SPEC: [CALL, Request|id, Options|dict, Procedure|uri, Arguments|list, ArgumentsKw|dict]
        if session.isWampEstablished == 1 then
            if self:_validateURI(dataObj[4]) then

                local rpcInfo = store:getRPC(session.realm, dataObj[4])

                if not rpcInfo then
                    -- WAMP SPEC: [ERROR, CALL, CALL.Request|id, Details|dict, Error|uri]
                    self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.CALL, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.no_suitable_callee" })
                else
                    local details = setmetatable({}, { __jsontype = 'object' })

                    if config.callerIdentification == "always" or
                            (config.callerIdentification == "auto" and
                                    ((dataObj[3].disclose_me ~= nil and dataObj[3].disclose_me == true) or
                                            (rpcInfo.disclose_caller == true))) then
                        details.caller = regId
                    end

                    if dataObj[3].receive_progress ~= nil and dataObj[3].receive_progress == true then
                        details.receive_progress = true
                    end

                    local calleeSess = store:getSession(rpcInfo.calleeSesId)
                    local invReqId = store:getRegId()

                    if dataObj[3].timeout ~= nil and
                            dataObj[3].timeout > 0 and
                            calleeSess.wampFeatures.callee.features.call_timeout == true and
                            calleeSess.wampFeatures.callee.features.call_canceling == true then

                        -- Caller specified Timeout for CALL processing and callee support this feature
                        local function callCancel(premature, calleeSess, invReqId)

                            local details = setmetatable({}, { __jsontype = 'object' })

                            -- WAMP SPEC: [INTERRUPT, INVOCATION.Request|id, Options|dict]
                            self:_putData(calleeSess, { WAMP_MSG_SPEC.INTERRUPT, invReqId, details })
                        end

                        local ok, err = ngx.timer.at(dataObj[3].timeout, callCancel, calleeSess, invReqId)

                        if not ok then
                            ngx.log(ngx.ERR, "failed to create timer: ", err)
                        end
                    end

                    store:addCallInvocation(dataObj[2], session.sessId, invReqId, calleeSess.sessId)

                    if #dataObj == 5 then
                        -- WAMP SPEC: [INVOCATION, Request|id, REGISTERED.Registration|id, Details|dict, CALL.Arguments|list]
                        self:_putData(calleeSess, { WAMP_MSG_SPEC.INVOCATION, invReqId, rpcInfo.registrationId, details, dataObj[5] })
                    elseif #dataObj == 6 then
                        -- WAMP SPEC: [INVOCATION, Request|id, REGISTERED.Registration|id, Details|dict, CALL.Arguments|list, CALL.ArgumentsKw|dict]
                        self:_putData(calleeSess, { WAMP_MSG_SPEC.INVOCATION, invReqId, rpcInfo.registrationId, details, dataObj[5], dataObj[6] })
                    else
                        -- WAMP SPEC: [INVOCATION, Request|id, REGISTERED.Registration|id, Details|dict]
                        self:_putData(calleeSess, { WAMP_MSG_SPEC.INVOCATION, invReqId, rpcInfo.registrationId, details })
                    end
                end
            else
                self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.CALL, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.invalid_uri" })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.REGISTER then -- WAMP SPEC: [REGISTER, Request|id, Options|dict, Procedure|uri]
        if session.isWampEstablished == 1 then
            if self:_validateURI(dataObj[4]) then

                local registrationId = store:registerSessionRPC(session.realm, dataObj[4], dataObj[3], regId)

                if not registrationId then
                    self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.REGISTER, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.procedure_already_exists" })
                else
                    -- WAMP SPEC: [REGISTERED, REGISTER.Request|id, Registration|id]
                    self:_putData(session, { WAMP_MSG_SPEC.REGISTERED, dataObj[2], registrationId })
                end
            else
                self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.REGISTER, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.invalid_uri" })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.UNREGISTER then -- WAMP SPEC: [UNREGISTER, Request|id, REGISTERED.Registration|id]
        if session.isWampEstablished == 1 then

            local rpc = store:unregisterSessionRPC(session.realm, dataObj[3], regId)

            if rpc ~= ngx.null then
                -- WAMP SPEC: [UNREGISTERED, UNREGISTER.Request|id]
                self:_putData(session, { WAMP_MSG_SPEC.UNREGISTERED, dataObj[2] })
            else
                self:_putData(session, { WAMP_MSG_SPEC.ERROR, WAMP_MSG_SPEC.UNREGISTER, dataObj[2], setmetatable({}, { __jsontype = 'object' }), "wamp.error.no_such_registration" })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.YIELD then
        -- WAMP SPEC: [YIELD, INVOCATION.Request|id, Options|dict]
        -- WAMP SPEC: [YIELD, INVOCATION.Request|id, Options|dict, Arguments|list]
        -- WAMP SPEC: [YIELD, INVOCATION.Request|id, Options|dict, Arguments|list, ArgumentsKw|dict]
        if session.isWampEstablished == 1 then

            local invoc = store:getInvocation(dataObj[2])
            local callerSess = store:getSession(invoc.callerSesId)
            local details = setmetatable({}, { __jsontype = 'object' })

            if dataObj[3].progress ~= nil and dataObj[3].progress == true then
                details.progress = true
            else
                store:removeInvocation(dataObj[2])
                store:removeCall(invoc.CallReqId)
            end

            if #dataObj == 4 then
                -- WAMP SPEC: [RESULT, CALL.Request|id, Details|dict, YIELD.Arguments|list]
                self:_putData(callerSess, { WAMP_MSG_SPEC.RESULT, invoc.CallReqId, details, dataObj[4] })
            elseif #dataObj == 5 then
                -- WAMP SPEC: [RESULT, CALL.Request|id, Details|dict, YIELD.Arguments|list, YIELD.ArgumentsKw|dict]
                self:_putData(callerSess, { WAMP_MSG_SPEC.RESULT, invoc.CallReqId, details, dataObj[4], dataObj[5] })
            else
                -- WAMP SPEC: [RESULT, CALL.Request|id, Details|dict]
                self:_putData(callerSess, { WAMP_MSG_SPEC.RESULT, invoc.CallReqId, details })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    elseif dataObj[1] == WAMP_MSG_SPEC.CANCEL then
        -- WAMP SPEC: [CANCEL, CALL.Request|id, Options|dict]
        if session.isWampEstablished == 1 then

            local wiCall = store:getCall(dataObj[2])
            local calleeSess = store:getSession(wiCall.calleeSesId)

            if calleeSess.wampFeatures.callee.features.call_canceling == true then
                local details = setmetatable({}, { __jsontype = 'object' })

                if dataObj[3].mode ~= nil then
                    details.mode = dataObj[3].mode
                end

                -- WAMP SPEC: [INTERRUPT, INVOCATION.Request|id, Options|dict]
                self:_putData(calleeSess, { WAMP_MSG_SPEC.INTERRUPT, wiCall.wiInvocId, details })
            end
        else
            self:_putData(session, { WAMP_MSG_SPEC.GOODBYE, setmetatable({}, { __jsontype = 'object' }), "wamp.error.system_shutdown" })
        end
    else
    end

    ngx.log(ngx.DEBUG, "Exiting receiveData()")
end

--
-- Retrieve data, available for session
--
-- regId - WAMP session registration ID
--
-- returns first WAMP message from the session data queue
--
function _M:getPendingData(regId)
    return store:getPendingData(regId)
end

--
-- Process lightweight publish POST data from client
--
-- sid - nginx session connection ID
-- realm - WAMP Realm to operate in
-- data - data, received through POST
--
function _M:processPostData(sid, realm, data)

    ngx.log(ngx.DEBUG, "Received POST data for processing in realm ", realm, ":", data)

    local dataObj = serializers.json.decode(data)
    local res
    local httpCode

    if dataObj[1] == WAMP_MSG_SPEC.PUBLISH then
        local regId, dataType = self.addConnection(sid, nil)

        -- Make a session legal :)
        local session = store:getSession(regId)
        session.isWampEstablished = 1
        session.realm = realm
        store:changeSession(regId, session)

        self.receiveData(regId, data)

        local cliData, cliErr = self.getPendingData(regId)
        if cliData ~= ngx.null then
            res = cliData
            httpCode = ngx.HTTP_FORBIDDEN
        else
            res = serializers.json.encode({ result = true, error = nil })
            httpCode = ngx.HTTP_OK
        end

        store:removeSession(regId)
    else
        res = serializers.json.encode({ result = false, error = "Message type not supported" })
        httpCode = ngx.HTTP_FORBIDDEN
    end

    return res, httpCode
end

return _M
