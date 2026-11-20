-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Ryan Gilmore
-- Minimal JSON reader for the test suite (objects, arrays, strings, numbers,
-- true/false/null). Enough for protocol/vectors.json; not a general library.
local J = {}

local function err(s, i, msg)
    error(string.format("json: %s at byte %d near %q", msg, i, s:sub(i, i + 10)), 0)
end

local function skip(s, i)
    local _, e = s:find("^[ \t\r\n]*", i)
    return e + 1
end

local parseValue

local function parseString(s, i)
    local out, j = {}, i + 1
    while true do
        local c = s:sub(j, j)
        if c == "" then err(s, j, "unterminated string") end
        if c == '"' then return table.concat(out), j + 1 end
        if c == "\\" then
            local n = s:sub(j + 1, j + 1)
            local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
            if map[n] then
                out[#out + 1] = map[n]; j = j + 2
            elseif n == "u" then
                local cp = tonumber(s:sub(j + 2, j + 5), 16)
                if not cp then err(s, j, "bad \\u escape") end
                out[#out + 1] = utf8.char(cp); j = j + 6
            else
                err(s, j, "bad escape")
            end
        else
            out[#out + 1] = c; j = j + 1
        end
    end
end

parseValue = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local obj = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            i = skip(s, i)
            if s:sub(i, i) ~= '"' then err(s, i, "expected key") end
            local k; k, i = parseString(s, i)
            i = skip(s, i)
            if s:sub(i, i) ~= ":" then err(s, i, "expected ':'") end
            local v; v, i = parseValue(s, i + 1)
            obj[k] = v
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "}" then return obj, i + 1 end
            if d ~= "," then err(s, i, "expected ',' or '}'") end
            i = i + 1
        end
    elseif c == "[" then
        local arr = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local v; v, i = parseValue(s, i)
            arr[#arr + 1] = v
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "]" then return arr, i + 1 end
            if d ~= "," then err(s, i, "expected ',' or ']'") end
            i = i + 1
        end
    elseif c == '"' then
        return parseString(s, i)
    elseif s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif s:sub(i, i + 3) == "null" then
        return nil, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        if not num or num == "" then err(s, i, "unexpected character") end
        return math.tointeger(tonumber(num)) or tonumber(num), i + #num
    end
end

function J.decode(s)
    local v, i = parseValue(s, 1)
    i = skip(s, i)
    if i <= #s then err(s, i, "trailing data") end
    return v
end

function J.readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("a")
    f:close()
    return J.decode(s)
end

return J
