---@module 'snacks'

---Provide an embedded `opencode` via [`snacks.terminal`](https://github.com/folke/snacks.nvim/blob/main/docs/terminal.md).
---@class opencode.provider.Snacks : opencode.Provider
---
---@field opts snacks.terminal.Opts
---@field attach_cmd? string
local Snacks = {}
Snacks.__index = Snacks
Snacks.name = "snacks"

---@class opencode.provider.snacks.Opts : snacks.terminal.Opts

---@param opts? opencode.provider.snacks.Opts
---@return opencode.provider.Snacks
function Snacks.new(opts)
  local self = setmetatable({}, Snacks)
  self.opts = opts or {}
  return self
end

---Check if `snacks.terminal` is available and enabled.
function Snacks.health()
  local snacks_ok, snacks = pcall(require, "snacks")
  ---@cast snacks Snacks
  if not snacks_ok then
    return "`snacks.nvim` is not available.", {
      "Install `snacks.nvim` and enable `snacks.terminal.`",
    }
  elseif not snacks.config.get("terminal", {}).enabled then
    return "`snacks.terminal` is not enabled.",
      {
        "Enable `snacks.terminal` in your `snacks.nvim` configuration.",
      }
  end

  return true
end

function Snacks:get(cmd)
  ---@type snacks.terminal.Opts
  local opts = vim.tbl_deep_extend("force", self.opts, { create = false })
  local terminal_cmd = cmd or self.cmd
  local win = require("snacks.terminal").get(terminal_cmd, opts)
  return win
end

function Snacks:toggle(attach_info)
  local cmd = self:_get_cmd(attach_info)
  require("snacks.terminal").toggle(cmd, self.opts)
end

---@param attach_info? { uri?: string, port?: number, cwd: string }
---@return string
function Snacks:_get_cmd(attach_info)
  if attach_info then
    if attach_info.uri then
      return string.format("opencode attach %s --dir %s", attach_info.uri, attach_info.cwd)
    end
    return string.format("opencode attach http://localhost:%d --dir %s", attach_info.port, attach_info.cwd)
  end
  return self.cmd
end

---@param attach_info? { uri?: string, port?: number, cwd: string }
function Snacks:start(attach_info)
  local cmd = self:_get_cmd(attach_info)
  if not self:get(cmd) then
    require("snacks.terminal").open(cmd, self.opts)
  end
end

function Snacks:stop()
  local win = self:get()
  if win then
    win:close()
  end
end

return Snacks
