-- Add current script path to the lua package search path,
-- this is necessary to require modules relative to this file.
local script_path = debug.getinfo(1, 'S').source:sub(2)
local script_dir = script_path:gsub('[/\\]*[^/\\]-$', '')
do
  script_dir = script_dir == '' and '.' or script_dir
  local dirsep, pathsep = package.config:match('(.)[\r\n]+(.)[\r\n]+')
  package.path = script_dir..dirsep..'?.lua'..pathsep..package.path
  package.path='/home/bart/projects/nelua/nelua-lang/?.lua;'..package.path
end

-- Required modules
local json = require 'json'
local utils = require 'utils'
local except = require 'nelua.utils.except'
local fs = require 'nelua.utils.fs'
local sstream = require 'nelua.utils.sstream'
local analyzer = require 'nelua.analyzer'
local AnalyzerContext = require 'nelua.analyzercontext'
local syntax = require 'nelua.syntaxdefs'()

-- Redirect stderr to a file so we can read debug information.
io.stderr = io.open(fs.join(script_dir, 'stderr.log'), 'a')
assert(io.stderr, 'failed to redirect stderr!')

-- Print to a file
local function pdebug(...)
  local ss = {...}
  ss[#ss] = '\n'
  io.stderr:write(table.concat(ss))
  io.stderr:flush()
end

-- All capabilities supported by this language server.
local LSPCapabilities = {
  hoverProvider= true,
}

-- Some LSP constants
local LSPErrors = {
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

-- Wait and read next JSON request, returning it as a table.
local function read_request()
  local header = {}
  -- parse all lines from header
  while true do
    local line = io.read('L')
    line = line:gsub('[\r\n]+$', '') -- strip \r\n from line ending
    if line == '' then break end -- empty line means end of header
    local field, value = line:match('^([%w-]+):%s*(.*)')
    header[field:lower()] = value
  end
  -- check content length
  local length = tonumber(header['content-length'])
  assert(length and length > 0, 'invalid header content-length')
  -- read the content
  local content = io.read(length)
  -- parse JSON
  return json.decode(content)
end

-- Send a JSON response.
local function send_response(id, result, error)
  local ans = {id=id, result=result, error=error}
  local content = json.encode(ans)
  local header = string.format('Content-Length: %d\r\n\r\n', #content)
  io.write(header..content)
  io.flush()
end

-- Send an error response.
local function send_error(id, code, message)
  send_response(id, nil, {code=code, message=message})
end

local function analyze_ast(filepath)
  local ast
  local ok, err = except.trycall(function()
    local parser = syntax.parser
    ast = parser:parse(fs.ereadfile(filepath), filepath)
    local context = AnalyzerContext(analyzer.visitors, parser, ast, 'c')
    analyzer.analyze(context)
  end)
  if not ok then
    pdebug(err)
  end
  return ast
end

local function analyze_and_find(filepath, textpos)
  local content = fs.readfile(filepath)
  local pos = utils.linecol2pos(content, textpos.line, textpos.character)
  local ast = analyze_ast(filepath)
  if not ast then return end
  local nodes = utils.find_nodes_by_pos(ast, pos)
  local lastnode = nodes[#nodes]
  if not lastnode then return end
  local loc = {node=lastnode}
  if lastnode.attr._symbol then
    loc.symbol = lastnode.attr
  end
  for i=#nodes,1,-1 do -- find scope
    local attr = nodes[i].attr
    if attr.scope then
      loc.scope = attr.scope
      break
    end
  end
  return loc
end

local function get_node_content(node)
  if not node or not node.src or not node.pos or not node.endpos then return end
  local text = node.src.content:sub(node.pos, node.endpos-1)
  text = text:gsub('%-%-.*',''):gsub('%s+$','')
  return text
end

local function markup_loc_info(loc)
  local ss = sstream()
  local attr = loc.node.attr
  local type = attr.type
  if type then
    if type.is_type then
      type = attr.value
      ss:add('**type** `', type.nickname or type.name, '`\n')
      local content = get_node_content(type.node)
      ss:add('```nelua\n')
      if content then
        ss:add('', content,'\n')
      else
        ss:add('', type:typedesc(),'\n')
      end
      ss:add('```')
    end
  end
  return ss:tostring()
end

-- Get hover information
local function handle_method(id, method, params)
  if method == 'textDocument/hover' then
    local loc = analyze_and_find(utils.uri2path(params.textDocument.uri), params.position)
    if loc then
      send_response(id, {contents = markup_loc_info(loc)})
    else
      send_response(id, {contents = ''})
    end
  else
    pdebug('LSP - unsupported method ' .. tostring(method))
    -- we must response that we were unable to fulfill the request
    send_error(id, LSPErrors.MethodNotFound, 'unsupported method')
  end
end

local function listen()
  pdebug('LSP - initialize')
  local shutdown = false
  local initialized = false
  for req in read_request do
    if req.method == 'initialize' then
      pdebug('LSP - initialize request')
      -- we must send back the supported capabilities
      send_response(req.id, {capabilities=LSPCapabilities})
    elseif req.method == 'initialized' then
      -- both client and server agree on initialization
      pdebug('LSP - initialized')
      initialized = true
    elseif req.method == 'shutdown' then
      pdebug('LSP - shutdown request')
      -- we now expect an exit method for the next request
      shutdown = true
    elseif req.method == 'exit' then
      pdebug('LSP - exit')
      -- exit with 0 (success) when shutdown was requested
      os.exit(shutdown and 0 or 1)
    elseif initialized and not shutdown then
      -- process usual requests
      handle_method(req.id, req.method, req.params)
    else -- invalid request when shutting down or initializing
      pdebug('LSP - invalid request ' .. tostring(req.method))
      send_error(req.id, LSPErrors.InvalidRequest, 'invalid request')
    end
  end
  pdebug('LSP - shutdown')
end

listen()
