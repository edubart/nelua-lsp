local fs = require 'nelua.utils.fs'
local relabel = require 'relabel'

local utils = {}

function utils.uri2path(uri)
  local file = uri:match('file://(.*)')
  file = fs.normpath(file)
  return file
end

function utils.linecol2pos(content, lineno, colno)
  -- expect zero based lineno/colno
  local i = 0
  local pos = 0
  for line in content:gmatch('[^\r\n]*[\r]?[\n]') do
    if i == lineno then
      pos = pos + colno
      break
    end
    i = i + 1
    pos = pos + #line
  end
  return pos + 1 -- return one-based
end

function utils.pos2textpos(content, pos)
  local lineno, colno = relabel.calcline(content, pos)
  return {line=lineno-1, character=colno-1} -- convert to zero-based
end

function utils.posrange2textrange(content, startpos, endpos)
  return {['start']=utils.pos2textpos(content, startpos),
          ['end']=utils.pos2textpos(content, endpos)}
end

local function find_nodes_by_pos(node, pos, foundnodes)
  if type(node) ~= 'table' then return end
  if node._astnode then
    if node.pos and pos >= node.pos and
       node.endpos and pos < node.endpos then
      foundnodes[#foundnodes+1] = node
    end
  end
  for i=1,node.nargs or #node do
    find_nodes_by_pos(node[i], pos, foundnodes)
  end
end

function utils.find_nodes_by_pos(node, pos)
  local foundnodes = {}
  find_nodes_by_pos(node, pos, foundnodes)
  return foundnodes
end

function utils.find_symbol_refs(node, pos)
  local foundnodes = {}
  find_nodes_by_pos(node, pos, foundnodes)
  return foundnodes
end

return utils
