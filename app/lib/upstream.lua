local openssl = require('openssl')
local digest = openssl.digest.digest
local base64 = openssl.base64
local random = openssl.random
local connect = require('creationix/coro-tcp').connect
local httpCodec = require('creationix/http-codec')
local websocketCodec = require('creationix/websocket-codec')

local git = require('creationix/git')
local deframe = git.deframe
local decodeTag = git.decoders.tag
local decodeTree = git.decoders.tree

local makeRemote = require('./codec').makeRemote
local wrapper = require('../lib/wrapper')
local readWrap, writeWrap = wrapper.reader, wrapper.writer

return function (storage, url)
  local protocol, host, port, path = string.match(url, "^(wss?)://([^:/]+):?(%d*)(/?[^#]*)")
  if protocol ~= "ws" then
    error("Sorry, only ws:// protocol currently supported")
  end
  port = tonumber(port) or 80
  local rawRead, rawWrite, socket = assert(connect(host, port))
  local read, updateDecoder = readWrap(rawRead, httpCodec.decoder())
  local write, updateEncoder = writeWrap(rawWrite, httpCodec.encoder())

  -- Perform the websocket handshake
  assert(websocketCodec.handshake({
    host = host,
    path = path,
    protocol = "lit"
  }, function (req)
    write(req)
    return read()
  end))

  -- Upgrade the protocol to websocket
  updateDecoder(websocketCodec.decode)
  updateEncoder(websocketCodec.encode)

  local remote = makeRemote(read, write, true)
  local upstream = {}

  -- Client: SEND tagObject

  -- Server: WANTS objectHash

  -- Client: SEND object

  -- Server: WANTS ...

  -- Client: SEND ...
  -- Client: SEND ...
  -- Client: SEND ...

  -- Server: DONE hash
  function upstream.push(hash)
    remote.writeAs("send", storage.load(hash))
    while true do
      local name, data = remote.read()
      if name == "wants" then
        for i = 1, #data do
          remote.writeAs("send", storage.load(data[i]))
        end
      elseif name == "done" then
        return data
      else
        error("Expected more wants or done in reply to send to server")
      end
    end
  end

        -- Client: WANT tagHash

        -- Server: SEND tagObject

        -- Client: WANT objectHash

        -- Server: SEND object

        -- Client: WANT ...
        -- Client: WANT ...
        -- Client: WANT ...

        -- Server: SEND ...
        -- Server: SEND ...
        -- Server: SEND ...

  function upstream.pull(hash)
    local list = {hash}
    local refs = {}
    repeat
      local hashes = list
      list = {}

      -- Fetch any hashes from list we don't have already
      local wants = {}
      for i = 1, #hashes do
        local hash = hashes[i]
        if not storage.has(hash) then
          wants[#wants + 1] = hash
        end
      end
      if #wants > 0 then
        remote.writeAs("wants", wants)
        for i = 1, #wants do
          local hash = hashes[i]
          local data = remote.readAs("send")
          assert(digest("sha1", data) == hash, "hash mismatch in result object")
          assert(storage.save(data) == hash)
        end
      end

      -- Process the hashes looking for child nodes
      for i = 1, #hashes do
        local hash = hashes[i]
        local data = storage.load(hash)
        local kind, body = deframe(data)
        if kind == "tag" then
          local tag = decodeTag(body)
          -- TODO: verify tag
          refs[tag.tag] = hash
          table.insert(list, tag.object)
        elseif kind == "tree" then
          local tree = decodeTree(body)
          for i = 1, #tree do
            local subHash = tree[i].hash
            table.insert(list, subHash)
          end
        end
      end
    until #list == 0
    for ref, hash in pairs(refs) do
      local name, version = string.match(ref, "^(.*)/v(.*)$")
      storage.writeTag(name, version, hash)
    end
    return refs
  end

      -- Client: WANTS hash

      -- Server: SEND data

  function upstream.load(hash)
    remote.writeAs("wants", {hash})
    local data = remote.readAs("send")
    assert(digest("sha1", data) == hash, "hash mismatch in result object")
    storage.save(data)
    return data
  end

      -- Client: MATCH name version

      -- SERVER: REPLY version hash

  function upstream.read(name, version)
    remote.writeAs("read", name .. " " .. version)
    return remote.readAs("reply")
  end

  function upstream.match(name, version)
    remote.writeAs("match", version and (name .. " " .. version) or name)
    local data = remote.readAs("reply")
    if data then
      return string.match(data, "^([^ ]+) (.*)$")
    end
  end

  --[[
  upstream.close()
  ----------------

  Called when the db is done with the connection.
  ]]--
  function upstream.close()
    return socket:close()
  end

  return upstream

end

