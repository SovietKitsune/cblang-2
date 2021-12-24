local parse = require 'parse'
local rex = require 'lpegrex'

local function initScope()
   local g = { const = true, start = 0, stop = 0 }

   return {
      _G = g,
      package = g,
      rawlen = g,
      loadfile = g,
      pairs = g,
      coroutine = g,
      arg = g,
      os = g,
      table = g,
      getmetatable = g,
      ipairs = g,
      tonumber = g,
      pcall = g,
      xpcall = g,
      io = g,
      select = g,
      warn = g,
      dofile = g,
      debug = g,
      utf8 = g,
      math = g,
      rawget = g,
      _VERSION = g,
      print = g,
      rawequal = g,
      type = g,
      collectgarbage = g,
      load = g,
      error = g,
      setmetatable = g,
      assert = g,
      next = g,
      string = g,
      tostring = g,
      require = g,
      rawset = g,
   }
end


-- I learned the oversized function trick from Teal (tl.type_check is 4k lines)
local function compile(source, file, included)
   local ast, err = parse(source)

   if not ast then
      -- TODO - nicer errors
      return nil, string.format(
         '%u:%u: %s\n%s\n%s',
         err.line,
         err.col,
         err.tag,
         err.details,
         string.rep(' ', err.col - 1) .. '^'
      )
   end

   local scopes = included and included.scopes or { initScope() }
   local errorBuff = included and included.errorBuff or {}
   local header = included and included.header or {}

   local hasMain = false
   local exports = {}
   local errors = {}
   local buff = {}

   local function push(...)
      table.insert(buff, table.concat({ ... }))
   end

   local function pushIndent(...)
      table.insert(buff, string.rep(' ', (#scopes - 2) * 3) .. table.concat({ ... }))
   end

   local function pushErr(msg, node)
      table.insert(errors, {
         msg = msg,
         start = node.pos,
         stop = node.endpos
      })
   end

   local function getVar(name)
      for i = 1, #scopes do
         local var = scopes[i][name]

         if var then
            return var, i
         end
      end
   end

   local function assertVar(name, node)
      local var, scope = getVar(name)

      if var then
         if scope == 1 then
            return pushErr('shadowing global variable', node)
         end

         local _, line = rex.calcline(source, var.start)

         pushErr('shadowing local variable declared at line ' .. line, node)
      end
   end

   local function pushVar(name, node, const, extra)
      assertVar(name, node)

      local base = {
         const = const or node[2] == 'const',
         start = node.pos,
         stop = node.endpos
      }

      if extra then
         for i, v in pairs(extra) do
            base[i] = v
         end
      end

      scopes[#scopes][name] = base
   end

   local function inc()
      table.insert(scopes, {})
   end

   local function dec()
      table.remove(scopes)
   end

   -- AAAAAAAAAAAAAAAAAAAAAAAAAAAAA
   -- TODO; write better
   local visitors = {}

   function visitors.visit(node, ...)
      if node and visitors[node.tag] then
         return visitors[node.tag](node, ...)
      end
   end

   function visitors.Block(node)
      inc()

      for i = 1, #node do
         push('\n')

         visitors.visit(node[i], true)
      end

      push('\n')

      dec()
   end

   visitors.Chunk = visitors.Block

   function visitors.BaseInclude(node)
      local adjustedPath = {}

      for i = 1, #node.path do
         table.insert(adjustedPath, node.path[i][1])
      end

      adjustedPath = table.concat(adjustedPath, package.config:sub(1, 1)) .. '.cb'

      local contents

      do
         local f = io.open(adjustedPath, 'r')

         if not f then
            return pushErr('Could not open file ' .. adjustedPath, node)
         end

         contents = f:read('*a')

         f:close()
      end

      contents = compile(contents, adjustedPath, {
         errorBuff = errorBuff,
         scopes = scopes,
         header = header,
      }):match('^%s*(.-)%s*$')

      table.insert(header, '--- ' .. adjustedPath .. ' ---\n' .. contents .. '\n--- END ---\n')
   end

   function visitors.FromNative(node)
      if not header.toLoad then
         header.toLoad = {}
      end

      local path = {}

      for i = 1, #node.path do
         table.insert(path, node.path[i][1])
      end

      table.insert(header.toLoad, table.concat(path, '.'))
   end

   function visitors.FromNativeRef(node)
      if not header.toRequire then
         header.toRequire = {}
      end

      if not header.vars then
         header.vars = {}
      end

      local path = {}

      for i = 1, #node.path do
         table.insert(path, node.path[i][1])
      end

      table.insert(header.toRequire, path)
      table.insert(header.vars, path[#path])

      pushVar(path[#path], node, true)
   end

   function visitors.Class(node)
      local name = node.name[1]

      table.insert(exports, name)

      if not header.vars then
         header.vars = {}
      end

      table.insert(header.vars, name)

      pushIndent(name, ' = {}\n')
      pushIndent('setmetatable(', name, ', {\n')

      inc()

      pushIndent('__call = function(_, ...)\n')

      inc()

      pushIndent('local self = setmetatable({}, { __index = ', name, ' })\n')

      if node.args then
         for i = 1, #node.args do
            local arg = node.args[i]

            if not getVar(arg[1]) then
               pushErr('Undefined variable ' .. arg[1], arg)
            end

            pushIndent('setmetatable(self, { __index = ', arg[1], '})\n')
         end
      end

      pushIndent('self:Start()\n')
      pushIndent('return self\n')

      dec()

      pushIndent('end\n')

      dec()

      pushIndent('})')

      local hasStart, hasMainFn

      for i = 1, #node do
         push('\n')

         visitors.visit(node[i], node)

         local fn = node[i]
         local fnName = fn.name[1]

         if fnName == 'Main' then
            hasMainFn = true

            if fn.static then
               pushErr('The Main method should not be marked as static', fn)
            end
         elseif fnName == 'Start' then
            hasStart = true

            if fn.static then
               pushErr('The Static method should not be marked as static', fn)
            end
         end
      end

      push('\n')

      if not hasStart then
         pushIndent('function ', node.name[1], ':Start() end')
      end

      if name == 'Main' then
         hasMain = true

         if not hasMainFn then
            pushErr('The Main class should have a Main method', node)
         end
      end
   end

   function visitors.FunctionCb(node, parent)
      pushIndent('function ', parent.name[1], (node.static and '.' or ':'), node.name[1], '(')

      for i = 1, #node.args do
         if i ~= 1 then
            push(', ')
         end

         push(node.args[i][1])
      end

      push(')')

      inc()

      for i = 1, #parent do
         local fn = parent[i]

         if fn.name[1] ~= 'Main' or fn.static then
            pushVar(fn.name[1], fn, true, {
               method = true
            })
         end
      end

      for i = 1, #node.args do
         pushVar(node.args[i][1], node.args[i])
      end

      for i = 1, #node do
         push('\n')

         visitors.visit(node[i], true)
      end

      push('\n')

      dec()

      pushIndent('end')
   end

   function visitors.Statement(node)
      visitors.visit(node[1], true)
   end

   -- Lua fun

   function visitors.Label(node)
      pushIndent('::', node[1], '::')
   end

   function visitors.Return(node)
      pushIndent('return ')

      for i = 1, #node[1] do
         if i ~= 1 then
            push(', ')
         end

         visitors.visit(node[1][i])
      end
   end

   function visitors.Break()
      pushIndent('break')
   end

   function visitors.Goto(node)
      pushIndent('goto ', node[1], '')
   end

   function visitors.Do(node)
      pushIndent('do\n')

      visitors.visit(node[1])

      pushIndent('end')
   end

   function visitors.While(node)
      pushIndent('while ')

      visitors.visit(node[1])

      pushIndent(' do\n')

      visitors.visit(node[2])

      pushIndent('end')
   end

   function visitors.Repeat(node)
      pushIndent('repeat\n')

      inc()

      for i = 1, #node[1] do
         push('\n')

         visitors.visit(node[1][i], true)
      end

      push('\n')

      -- repeat has delayed scope closing
      push(string.rep((#scopes - 3) * 3, ' ') .. 'until ')

      visitors.visit(node[2])

      dec()
   end

   function visitors.If(node)
      pushIndent('if ')

      visitors.visit(node[1])

      push(' then')

      visitors.visit(node[2], true)

      for i = 1, #node[3] do
         local elif = node[3][i]
         pushIndent('elseif ')

         visitors.visit(elif[1])

         push(' then')

         visitors.visit(node[elif[2]], true)
      end

      if node[4] then
         pushIndent('else')

         visitors.visit(node[4], true)
      end

      pushIndent('end')
   end

   function visitors.ForNum(node)
      pushIndent('for ')

      inc()

      local name = node[1][1]

      pushVar(name)

      push(name, ' = ')

      visitors.visit(node[2])

      push(', ')

      visitors.visit(node[3])

      if node[5] then
         push(', ')

         visitors.visit(node[4])
      end

      push('do\n')

      local block = node[5] and node[5] or node[4]

      for i = 1, #block do
         push('\n')

         visitors.visit(block[i], true)
      end

      push('\n')

      dec()

      pushIndent('end')
   end

   function visitors.ForIn(node)
      pushIndent('for ')

      inc() -- Scope starts early to capture the loop vars

      for i = 1, #node[1] do
         if i ~= 1 then
            push(', ')
         end

         push(node[1][i][1])
      end

      push(' in ')

      for i = 1, #node[2] do
         if i ~= 1 then
            push(', ')
         end

         visitors.visit(node[2][i])
      end

      for i = 1, #node[1] do
         pushVar(node[1][i][1])
      end

      push(' do\n')

      for i = 1, #node[3] do
         push('\n')

         visitors.visit(node[3][i], true)
      end

      push('\n')

      dec()

      push('end')
   end

   function visitors.VarDecl(node)
      pushIndent('local ')

      for i = 1, #node[1] do
         if i ~= 1 then
            push(', ')
         end

         local ident = node[1][i]

         pushVar(ident[1], ident)

         push(ident[1])

         if ident[2] then
            push(' <')

            push(ident[2])

            push('>')
         end
      end

      if node[2] then
         push(' = ')

         for i = 1, #node[2] do
            if i ~= 1 then
               push(', ')
            end

            visitors.visit(node[2][i])
         end
      end
   end

   function visitors.Assign(node)
      local toDefine = {}
      local toAssign = {}

      local indented = false

      for i = 1, #node[1] do
         local left = node[1][i]

         if left.tag == 'Id' then
            local var = getVar(left[1])

            if var and var.const then
               pushErr('Unable to assign to constant variable', node)
            elseif not var then
               table.insert(toDefine, i)

               pushVar(left[1], left)
            else
               if not indented then
                  indented = true
                  pushIndent()
               end

               table.insert(toAssign, i)

               push(left[1])
            end
         else
            if not indented then
               indented = true
               pushIndent()
            end

            table.insert(toAssign, i)

            visitors.visit(left)
         end
      end

      if #toAssign > 0 then
         push(' = ')

         for i = 1, #toAssign do
            if i ~= 1 then
               push(', ')
            end

            visitors.visit(node[2][toAssign[i]])
         end
      end

      if #toDefine > 0 then
         if #toAssign > 0 then
            push('\n')
         end

         pushIndent('local ')

         for i = 1, #toDefine do
            if i ~= 1 then
               push(', ')
            end

            push(node[1][toDefine[i]][1])
         end

         push(' = ')

         for i = 1, #toDefine do
            if i ~= 1 then
               push(', ')
            end

            visitors.visit(node[2][toDefine[i]])
         end
      end
   end

   function visitors.Number(node)
      push(node[1])
   end

   function visitors.String(node)
      push('\'',
         node[1]:gsub('[\\\'\a\b\f\n\r\t\v\z]', {
            ['\\'] = '\\\\',
            ['\''] = '\\\'',
            ['\a'] = '\\a',
            ['\b'] = '\\b',
            ['\f'] = '\\f',
            ['\n'] = '\\n',
            ['\r'] = '\\r',
            ['\t'] = '\\t',
            ['\v'] = '\\v',
            ['\z'] = '\\z'
         }
      ), '\'')
   end

   function visitors.Boolean(node)
      push(tostring(node[1]))
   end

   function visitors.Nil()
      push('nil')
   end

   function visitors.Varargs()
      push('...')
   end

   function visitors.Id(node)
      local var = getVar(node[1])

      if not var then
         pushErr('Undefined variable ' .. node[1], node)
      end

      if node[1] == 'this' then
         return push('self')
      end

      push(node[1])
   end

   function visitors.Function(node)
      push('function(')

      for i = 1, #node[1] do
         if i ~= 1 then
            push(', ')
         end

         push(node[1][i])
      end

      push(')')

      visitors.visit(node[2])

      push('end')
   end

   function visitors.Table(node)
      push('{ ')

      for i = 1, #node do
         if i ~= 1 then
            push(', ')
         end

         visitors.visit(node[i])
      end

      push(#node > 0 and ' ' or '', '}')
   end

   function visitors.Pair(node)
      push(node[1], ' = ')

      visitors.visit(node[2])
   end

   function visitors.Paren(node)
      push('(')

      visitors.visit(node[1])

      push(')')
   end

   function visitors.BinaryOp(node)
      visitors.visit(node[1])

      if node[2] == '^' then
         push(node[2])
      else
         push(' ', node[2], ' ')
      end

      visitors.visit(node[3])
   end

   function visitors.UnaryOp(node)
      push(node[1], node[1] == 'not' and ' ' or '')

      visitors.visit(node[2])
   end

   local drillable = {
      KeyIndex = 2,
      DotIndex = 2,
      ColonIndex = 2,
      CallMethod = 3,
      CallIndex = 3,
   }

   local function drill(node, children)
      children = children or {}

      table.insert(children, node[1])

      local pos = drillable[node.tag]

      if pos then
         drill(node[pos], children)
      end

      return children
   end

   function visitors.DotIndex(node)
      local path = drill(node)

      for i = #path, 1, -1 do
         local element = path[i]

         if i == #path then
            if not getVar(element) then
               pushErr('Undefined variable ' .. element, node)
            end
         end

         if type(element) == 'string' then
            if i ~= #path then
               push('.')
            end

            push(element)
         else
            push('[')

            visitors.visit(element)

            push(']')
         end
      end
   end

   function visitors.Call(node, parent)
      if parent then
         pushIndent()
      end

      local name = node[2][1]
      local var = getVar(name)

      if var and var.method then
         push('self:', name)
      else
         local path = drill(node[2])

         for i = #path, 1, -1 do
            local element = path[i]

            if i == #path then
               if not getVar(element) then
                  pushErr('Undefined variable ' .. element, node)
               end
            end

            if type(element) == 'string' then
               if i ~= #path then
                  push('.')
               end

               push(element)
            else
               push('[')

               visitors.visit(element)

               push(']')
            end
         end
      end

      push('(')

      for i = 1, #node[1] do
         if i ~= 1 then
            push(', ')
         end

         visitors.visit(node[1][i])
      end

      push(')')
   end

   function visitors.CallMethod(node, parent)
      if parent then
         pushIndent()
      end

      local path = drill(node)

      for i = #path, 1, -1 do
         local element = path[i]

         if i == #path then
            if not getVar(element) then
               pushErr('Undefined variable ' .. element, node)
            end
         end

         if type(element) == 'string' then
            if i ~= 1 and i ~= #path then
               push('.')
            elseif i == 1 then
               push(':')
            end

            push(element)
         else
            push('[')

            visitors.visit(element)

            push(']')
         end
      end

      push('(')

      for i = 1, #node[2] do
         if i ~= 1 then
            push(', ')
         end

         visitors.visit(node[2][i])
      end

      push(')')
   end

   for i = 1, #ast do
      local node = ast[i]

      if node.tag == 'Class' then
         pushVar(node.name[1], node, true)
      end
   end

   visitors.visit(ast)

   if not included then
      table.insert(buff, 1, table.concat(header))

      if header.toLoad then
         table.insert(buff, 1, '--- END ---\n')

         for i = 1, #header.toLoad do
            table.insert(buff, 1, '__globalLoader(require "' .. header.toLoad[i] .. '")\n')
         end

         local loader = table.concat({
            'local function __globalLoader(t)',
            '   local target = _ENV or _G',
            '   for i, v in pairs(t) do',
            '      target[i] = v',
            '   end',
            'end\n'
         }, '\n')

         table.insert(buff, 1, loader)

         table.insert(buff, 1, '--- Global Loader ---\n')
      end

      if header.toRequire then
         table.insert(buff, 1, '--- END ---\n')

         for i = 1, #header.toRequire do
            local path = header.toRequire[i]

            table.insert(buff, 1, path[#path] .. ' = require "' .. table.concat(path, '.') .. '"\n')
         end

         table.insert(buff, 1, '--- Requires ---\n')
      end

      if header.vars then
         table.insert(buff, 1, 'local ' .. table.concat(header.vars, ', ') .. '\n')
      end

      if not hasMain then
         pushIndent('return {\n')

         inc()

         for i = 1, #exports do
            pushIndent(exports[i], ' = ', exports[i], i ~= #exports and ',' or '', '\n')
         end

         dec()

         pushIndent('}')
      else
         pushIndent('Main():Main()')
      end
   end

   for i = 1, #errors do
      local error = errors[i]

      local col, line = rex.calcline(source, error.start)

      table.insert(errorBuff, string.format('%s:%u:%u: %s', file, col, line, error.msg))
   end

   return table.concat(buff), errorBuff
end

return compile
