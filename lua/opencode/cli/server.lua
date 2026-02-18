local M = {}

---An `opencode` server process and some details about it.
---@class opencode.cli.server.Server
---@field port number
---@field cwd string
---@field title string
---@field subagents opencode.cli.client.Agent[]

---An `opencode` process.
---Retrieval is platform-dependent.
---@class opencode.cli.server.Process
---@field pid number
---@field port number

---@return boolean
local function is_windows()
  return vim.fn.has("win32") == 1
end

---@return opencode.cli.server.Process[]
local function get_processes_unix()
  -- Find PIDs of all opencode processes, regardless of how they were started.
  -- We filter by listening ports (via lsof) below - only server processes will have ports.
  -- This catches `opencode --port`, `opencode serve`, `opencode web`, etc.
  local pgrep = vim.system({ "pgrep", "-f", "opencode" }, { text = true }):wait()
  require("opencode.util").check_system_call(pgrep, "pgrep")

  local processes = {}
  for pgrep_line in pgrep.stdout:gmatch("[^\r\n]+") do
    local pid = tonumber(pgrep_line)
    if pid then
      -- Get the port for the PID
      local lsof = vim
        .system({ "lsof", "-w", "-iTCP", "-sTCP:LISTEN", "-P", "-n", "-a", "-p", tostring(pid) }, { text = true })
        :wait()
      require("opencode.util").check_system_call(lsof, "lsof")
      for line in lsof.stdout:gmatch("[^\r\n]+") do
        local parts = vim.split(line, "%s+")
        if parts[1] ~= "COMMAND" then -- Skip header
          local port_str = parts[9] and parts[9]:match(":(%d+)$") -- e.g. "127.0.0.1:12345" -> "12345"
          if port_str then
            local port = tonumber(port_str)
            if port then
              table.insert(processes, {
                pid = pid,
                port = port,
              })
            end
          end
        end
      end
    end
  end
  return processes
end

---@return opencode.cli.server.Process[]
local function get_processes_windows()
  local ps_script = [[
Get-Process -Name '*opencode*' -ErrorAction SilentlyContinue |
ForEach-Object {
  $ports = Get-NetTCPConnection -State Listen -OwningProcess $_.Id -ErrorAction SilentlyContinue
  if ($ports) {
    foreach ($port in $ports) {
      [PSCustomObject]@{pid=$_.Id; port=$port.LocalPort}
    }
  }
} | ConvertTo-Json -Compress
]]
  local ps = vim.system({ "powershell", "-NoProfile", "-Command", ps_script }):wait()
  require("opencode.util").check_system_call(ps, "PowerShell")
  if ps.stdout == "" then
    return {}
  end
  -- The Powershell script should return the response as JSON to ease parsing.
  local ok, processes = pcall(vim.fn.json_decode, ps.stdout)
  if not ok then
    error("Failed to parse PowerShell output: " .. tostring(processes), 0)
  end
  if processes.pid then
    -- A single process was found, so wrap it in a table.
    processes = { processes }
  end
  return processes
end

---@param port number
---@return Promise<opencode.cli.server.Server>
local function get_server(port)
  local Promise = require("opencode.promise")
  return Promise
    .new(function(resolve, reject)
      require("opencode.cli.client").get_path(port, function(path)
        local cwd = path.directory or path.worktree
        if cwd then
          resolve(cwd)
        else
          reject("No `opencode` responding on port: " .. port)
        end
      end, function()
        reject("No `opencode` responding on port: " .. port)
      end)
    end)
    -- Serial instead of parallel so that `get_path` has verified it's a server
    :next(
      function(cwd) ---@param cwd string
        return Promise.all({
          cwd,
          Promise.new(function(resolve)
            require("opencode.cli.client").get_sessions(port, function(session)
              -- This will be the most recently interacted session.
              -- Unfortunately `opencode` doesn't provide a way to get the currently selected TUI session.
              -- But they will probably have interacted with the session they want to connect to most recently.
              local title = session[1] and session[1].title or "<No sessions>"
              resolve(title)
            end)
          end),
          Promise.new(function(resolve)
            require("opencode.cli.client").get_agents(port, function(agents)
              local subagents = vim.tbl_filter(function(agent)
                return agent.mode == "subagent"
              end, agents)
              resolve(subagents)
            end)
          end),
        })
      end
    )
    :next(function(results) ---@param results { [1]: string, [2]: string, [3]: opencode.cli.client.Agent[] }
      return {
        port = port,
        cwd = results[1],
        title = results[2],
        subagents = results[3],
      }
    end)
end

---@return Promise<opencode.cli.server.Server[]>
local function get_all_servers()
  local Promise = require("opencode.promise")
  return Promise.new(function(resolve, reject)
    local processes
    if is_windows() then
      processes = get_processes_windows()
    else
      processes = get_processes_unix()
    end
    if #processes == 0 then
      reject("No `opencode` processes found")
    else
      resolve(processes)
    end
  end):next(function(processes) ---@param processes opencode.cli.server.Process[]
    local get_servers = vim.tbl_map(function(process) ---@param process opencode.cli.server.Process
      return get_server(process.port)
    end, processes)
    return Promise.all_settled(get_servers):next(function(results)
      local servers = {}
      for _, result in ipairs(results) do
        -- We expect non-servers to reject
        if result.status == "fulfilled" then
          table.insert(servers, result.value)
        end
      end
      if #servers == 0 then
        error("No `opencode` servers found", 0)
      end
      return servers
    end)
  end)
end

---@return Promise<opencode.cli.server.Server|nil>
function M.get_first_server()
  local Promise = require("opencode.promise")
  return Promise.new(function(resolve, reject)
    local processes
    if is_windows() then
      processes = get_processes_windows()
    else
      processes = get_processes_unix()
    end
    if #processes == 0 then
      resolve(nil)
    else
      resolve(processes)
    end
  end):next(function(processes) ---@param processes opencode.cli.server.Process[]
    if not processes or #processes == 0 then
      return nil
    end

    ---@param process opencode.cli.server.Process
    local function try_next(i)
      if i > #processes then
        return nil
      end
      local process = processes[i]
      return get_server(process.port):next(function(server)
        return server
      end):catch(function()
        return try_next(i + 1)
      end)
    end

    return try_next(1)
  end)
end

---Attempt to get the `opencode` server's port. Tries, in order:
---
---1. The currently subscribed server in `opencode.events`.
---2. The configured port in `require("opencode.config").opts.port`.
---3. Any running opencode server, using `opencode attach` to connect.
---4. Calling `require("opencode.provider").start()` to launch a new server, then retrying the above.
---
---Upon success, subscribes to the server's events.
---
---@param launch boolean? Whether to launch a new server if none found. Defaults to true.
---@return Promise<opencode.cli.server.Server>
function M.get(launch)
  launch = launch ~= false

  local Promise = require("opencode.promise")
  return Promise.resolve(
    require("opencode.events").connected_server and require("opencode.events").connected_server.port
      or require("opencode.config").opts.port
  )
    :next(function(priority_port) ---@param priority_port number
      if priority_port then
        return Promise.resolve(priority_port)
      else
        return M.get_first_server():next(function(server) ---@param server opencode.cli.server.Server|nil
          if server then
            return server
          end
          error("No `opencode` servers found")
        end)
      end
    end)
    :next(function(server_or_port) ---@param server_or_port number|opencode.cli.server.Server
      local server
      local port
      if type(server_or_port) == "number" then
        port = server_or_port
      else
        server = server_or_port
        port = server.port
      end
      return get_server(port):next(function(s) ---@param s opencode.cli.server.Server
        local attach_info = server and { port = s.port, cwd = vim.fn.getcwd() } or nil
        require("opencode.provider").start(attach_info)
        return s
      end)
    end)
    :next(function(server) ---@param server opencode.cli.server.Server
      require("opencode.events").connect(server)
      return server
    end)
    :catch(function(err)
      if not err then
        -- Do nothing when select is cancelled
        return Promise.reject()
      end

      return Promise.new(function(resolve, reject)
        if launch then
          local start_ok, start_result = pcall(require("opencode.provider").start)
          if not start_ok then
            return reject("Error starting `opencode`: " .. start_result)
          end

          -- Wait for the provider to start
          vim.defer_fn(function()
            resolve(true)
          end, 2000)
        else
          -- Don't attempt to recover, just propagate the original error
          reject(err)
        end
      end):next(function()
        -- Retry
        return M.get(false)
      end)
    end)
end

return M
