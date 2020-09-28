local json = require 'json'
local console  = require 'nelua.utils.console'

local server = {
  -- List of callbacks for each method.
  methods = {},
  -- Table of capabilities supported by this language server.
  capabilities = {}
}

-- Some LSP constants
local LSPErrorsCodes = {
  ParseError = -32700,
  InvalidRequest = -32600,
  MethodNotFound = -32601,
  InvalidParams = -32602,
  InternalError = -32603,
  serverErrorStart = -32099,
  serverErrorEnd = -32000,
  ServerNotInitialized = -32002,
  UnknownErrorCode = -32001,
}

-- Send a JSON response.
function server.send_response(id, result, error)
  local ans = {id=id, result=result, error=error}
  local content = json.encode(ans)
  local header = string.format('Content-Length: %d\r\n\r\n', #content)
  server.stdout:write(header..content)
  server.stdout:flush()
end

-- Send an error response with optional message.
function server.send_error(id, code, message)
  if type(code) == 'string' then
    -- convert a named code to its numeric error code
    message = message or code
    code = LSPErrorsCodes[code]
  end
  message = message or 'Error: '..tostring(code)
  server.send_response(id, nil, {code=code, message=message})
end

-- Wait and read next JSON request, returning it as a table.
local function read_request()
  local header = {}
  -- parse all lines from header
  while true do
    local line = server.stdin:read('L')
    line = line:gsub('[\r\n]+$', '') -- strip \r\n from line ending
    if line == '' then break end -- empty line means end of header
    local field, value = line:match('^([%w-]+):%s*(.*)')
    if field and value then
      header[field:lower()] = value
    end
  end
  -- check content length
  local length = tonumber(header['content-length'])
  assert(length and length > 0, 'invalid header content-length')
  -- read the content
  local content = server.stdin:read(length)
  -- parse JSON
  return json.decode(content)
end

-- Listen for incoming requests until the server is requested to shutdown.
function server.listen(stdin, stdout)
  server.stdin, server.stdout = stdin, stdout
  console.debug('LSP - listening')
  local shutdown = false
  local initialized = false
  for req in read_request do
    console.debug('LSP - '..req.method)
    if req.method == 'initialize' then
      -- send back the supported capabilities
      server.send_response(req.id, {capabilities=server.capabilities})
    elseif req.method == 'initialized' then
      -- both client and server agree on initialization
      initialized = true
    elseif req.method == 'shutdown' then
      -- we now expect an exit method for the next request
      shutdown = true
    elseif req.method == 'exit' then
      -- exit with 0 (success) when shutdown was requested
      os.exit(shutdown and 0 or 1)
    elseif initialized and not shutdown then
      -- process usual requests
      local method = server.methods[req.method]
      if method then
        local ok, err = pcall(method, req.id, req.params)
        if not ok then
          local errmsg = 'error while handling method:\n'..tostring(err)
          server.send_error(req.id, 'InternalError', errmsg)
          console.debug(errmsg)
        end
      else
        console.debug('error: unsupported method "'.. tostring(method)..'"')
        -- we must response that we were unable to fulfill the request
        server.send_error(req.id, 'MethodNotFound')
      end
    else -- invalid request when shutting down or initializing
      console.debug('error: invalid request "'..tostring(req.method)..'"')
      server.send_error(req.id, 'InvalidRequest')
    end
  end
  console.debug('LSP - connection closed')
end

return server
