--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local util        = require("apisix.plugins.grpc-transcode.util")
local grpc_proto  = require("apisix.plugins.grpc-transcode.proto")
local core   = require("apisix.core")
local pb     = require("pb")
local ngx    = ngx
local string = string
local ngx_decode_base64 = ngx.decode_base64
local ipairs = ipairs
local pcall  = pcall
local type          = type
local pairs         = pairs
local setmetatable  = setmetatable

pb.option "decode_default_array"
-- Protobuf repeated field label value
local PROTOBUF_REPEATED_LABEL = 3
local repeated_label = PROTOBUF_REPEATED_LABEL

local function fetch_proto_array_names(proto_obj)
    local names = {}
    if type(proto_obj) == "table" then
        for k,v in pairs(proto_obj) do
            if type(v) == "table" then
                local sub_names = fetch_proto_array_names(v)
                for sub_name,_ in pairs(sub_names) do
                    names[sub_name] = 1
                end
            end
        end
        if proto_obj["label"] == repeated_label then
            if proto_obj["name"] then
                names[proto_obj["name"]] = 1
            end
        end
    end
    return names
end

local function set_default_array(tab, array_names)
    if type(tab) ~= "table" then
        return
    end
    for k, v in pairs(tab) do
        if type(v) == "table" then
            if array_names[k] == 1 then
                setmetatable(v, core.json.array_mt)
            end
            set_default_array(v, array_names)
        end
    end
end


local function handle_error_response(status_detail_type, proto)
    local err_msg

    local grpc_status = ngx.header["grpc-status-details-bin"]
    if grpc_status then
        grpc_status = ngx_decode_base64(grpc_status)
        if grpc_status == nil then
            err_msg = "grpc-status-details-bin is not base64 format"
            ngx.arg[1] = err_msg
            return err_msg
        end

        local status_pb_state = grpc_proto.fetch_status_pb_state()
        local old_pb_state = pb.state(status_pb_state)

        local ok, decoded_grpc_status = pcall(pb.decode, "grpc_status.ErrorStatus", grpc_status)
        pb.state(old_pb_state)
        if not ok then
            err_msg = "failed to call pb.decode to decode grpc-status-details-bin"
            ngx.arg[1] = err_msg
            return err_msg .. ", err: " .. decoded_grpc_status
        end

        if not decoded_grpc_status then
            err_msg = "failed to decode grpc-status-details-bin"
            ngx.arg[1] = err_msg
            return err_msg
        end

        local details = decoded_grpc_status.details
        if status_detail_type and details then
            local decoded_details = {}
            for _, detail in ipairs(details) do
                local pb_old_state = pb.state(proto.pb_state)
                local ok, err_or_value = pcall(pb.decode, status_detail_type, detail.value)
                pb.state(pb_old_state)
                if not ok then
                    err_msg = "failed to call pb.decode to decode details in "
                           .. "grpc-status-details-bin"
                    ngx.arg[1] = err_msg
                    return err_msg .. ", err: " .. err_or_value
                end

                if not err_or_value then
                    err_msg = "failed to decode details in grpc-status-details-bin"
                    ngx.arg[1] = err_msg
                    return err_msg
                end

                core.table.insert(decoded_details, err_or_value)
            end

            decoded_grpc_status.details = decoded_details
        end

        local resp_body = {error = decoded_grpc_status}
        local response, err = core.json.encode(resp_body)
        if not response then
            err_msg = "failed to json_encode response body"
            ngx.arg[1] = err_msg
            return err_msg .. ", error: " .. err
        end

        ngx.arg[1] = response
    end
end


return function(ctx, proto, service, method, pb_option, show_status_in_body, status_detail_type)
    local buffer = core.response.hold_body_chunk(ctx)
    if not buffer then
        return nil
    end

    -- handle error response after the last response chunk
    if ngx.status >= 300 and show_status_in_body then
        return handle_error_response(status_detail_type, proto)
    end

    -- when body has already been read by other plugin
    -- the buffer is an empty string
    if buffer == "" and ctx.resp_body then
        buffer = ctx.resp_body
    end

    local m = util.find_method(proto, service, method)
    if not m then
        return false, "2.Undefined service method: " .. service .. "/" .. method
                      .. " end."
    end

    if not ngx.req.get_headers()["X-Grpc-Web"] then
        buffer = string.sub(buffer, 6)
    end

    local pb_old_state = pb.state(proto.pb_state)
    util.set_options(proto, pb_option)

    local err_msg
    local decoded = pb.decode(m.output_type, buffer)
    pb.state(pb_old_state)
    if not decoded then
        err_msg = "failed to decode response data by protobuf"
        ngx.arg[1] = err_msg
        return err_msg
    end

    local array_names = fetch_proto_array_names(proto)
    set_default_array(decoded, array_names)

    local response, err = core.json.encode(decoded)
    if not response then
        err_msg = "failed to json_encode response body"
        ngx.arg[1] = err_msg
        return err_msg .. ", err: " .. err
    end

    ngx.arg[1] = response
    return nil
end
