local M = {}

local logError = vim.log.levels.ERROR
local expand = vim.fn.expand
local fn = vim.fn
local cmd = vim.cmd

local function leaveVisualMode()
	-- https://github.com/neovim/neovim/issues/17735#issuecomment-1068525617
	local escKey = vim.api.nvim_replace_termcodes("<Esc>", false, true, true)
	vim.api.nvim_feedkeys(escKey, "nx", false)
end

--------------------------------------------------------------------------------

local function fileExists(filepath)
	local file = io.open(filepath, "r")
	if file then io.close(file) end
	return file ~= nil
end

---Performing common file operation tasks
---@param op string rename|duplicate|new|newFromSel
local function fileOp(op)
	local dir = expand("%:p:h")
	local oldName = expand("%:t")
	local oldNameNoExt = oldName:gsub("%.%w+$", "")
	local oldExt = expand("%:e")
	if oldExt ~= "" then oldExt = "." .. oldExt end

	local prevReg
	if op == "newFromSel" then
		prevReg = fn.getreg("z")
		leaveVisualMode()
		cmd([['<,'>delete z]])
	end

	local promptStr, prefill
	if op == "duplicate" then
		promptStr = "Duplicate File as: "
		prefill = oldNameNoExt .. "-1"
	elseif op == "rename" then
		promptStr = "Rename File to: "
		prefill = oldNameNoExt
	elseif op == "move-rename" then
		promptStr = "Move & Rename File to: "
		prefill = dir .. "/"
	elseif op == "new" or op == "newFromSel" then
		promptStr = "Name for New File: "
		prefill = ""
	end

	-- selene: allow(high_cyclomatic_complexity)
	-- INFO completion = "dir" allows for completion via cmp-omni
	vim.ui.input({ prompt = promptStr, default = prefill, completion = "dir" }, function(newName)
		-- validation
		local invalidName = false
		local sameName
		if newName then
			invalidName = newName:find("^%s*$")
				or newName:find("[\\:]")
				or newName:find("/$")
				or (newName:find("^/") and not op == "move-rename")
			sameName = newName == oldName
		end
		if not newName or invalidName or sameName then -- cancel
			if op == "newFromSel" then
				cmd.undo() -- undo deletion
				fn.setreg("z", prevReg) -- restore register content
			end
			if invalidName then
				vim.notify("Invalid filename.", logError)
			elseif sameName then
				vim.notify("Cannot use the same filename.", logError)
			end
			return
		end

		-- create folders if necessary
		-- TODO upon release of neovim 0.9, use `:write ++p` https://twitter.com/Neovim/status/1589469857388834816?s=20&t=KNpSU7IESQAAWQwG04OjTQ
		local hasPath = newName:find("/")
		if hasPath then
			local newFolder = newName:gsub("/.-$", "")
			fn.mkdir(newFolder, "p")
		end

		local extProvided = newName:find(".%.[^/]*$") -- non-leading dot to not include dotfiles without extension
		if not extProvided then newName = newName .. oldExt end
		local newFilePath = (op == "move-rename") and newName or dir .. "/" .. newName

		cmd.update() -- save current file; needed for users with `hidden=false`
		if op == "duplicate" then
			cmd.saveas(newFilePath)
			cmd.edit(newFilePath)
			vim.notify('Duplicated "' .. oldName .. '" as "' .. newName .. '".')
		elseif op == "rename" or op == "move-rename" then
			if fileExists(newFilePath) then
				vim.notify('Could not rename file: File with name "'..newName..'" already exists.', logError)
				return
			end
			local success, errormsg = os.rename(oldName, newName)
			if success then
				cmd.edit(newFilePath)
				cmd.bwipeout("#")
				vim.notify('Renamed "' .. oldName .. '" to "' .. newName .. '".')
			else
				vim.notify("Could not rename file: " .. errormsg, logError)
			end
		elseif op == "new" or op == "newFromSel" then
			cmd.edit(newFilePath)
			if op == "newFromSel" then
				cmd("put z") -- cmd.put("z") does not work here :/
				fn.setreg("z", prevReg) -- restore register content
			end
			cmd.write(newFilePath)
		end
	end)
end

---Rename Current File
function M.renameFile() fileOp("rename") end

---Move and Rename Current File
function M.moveAndRenameFile() fileOp("move-rename") end

---Duplicate Current File
function M.duplicateFile() fileOp("duplicate") end

---Create New File
function M.createNewFile() fileOp("new") end

---Move Selection to New File
function M.moveSelectionToNewFile() fileOp("newFromSel") end

--------------------------------------------------------------------------------

---copying file information
---@param operation string filename|filepath
local function copyOp(operation)
	local reg = '"'
	local clipboardOpt = vim.opt.clipboard:get()
	local useSystemClipb = #clipboardOpt > 0 and clipboardOpt[1]:find("unnamed")
	if useSystemClipb then reg = "+" end

	local toCopy = expand("%:p")
	if operation == "filename" then toCopy = expand("%:t") end

	fn.setreg(reg, toCopy)
	vim.notify("COPIED\n" .. toCopy)
end

---Copy absolute path of current file
function M.copyFilepath() copyOp("filepath") end

---Copy name of current file
function M.copyFilename() copyOp("filename") end

--------------------------------------------------------------------------------

---Makes current file executable
function M.chmodx()
	local filename = expand("%")
	local perm = fn.getfperm(filename)
	perm = perm:gsub("r(.)%-", "r%1x") -- add x to every group that has r
	fn.setfperm(filename, perm)
	vim.notify("Execution Permission granted.")
end

---Trash the current File.
---@param opts? table
function M.trashFile(opts)
	cmd.update { bang = true }
	local trash
	local home = os.getenv("HOME")

	-- Default trash locations
	if fn.has("linux") == 1 then
		local xdg_data = os.getenv("XDG_DATA_HOME")
		trash = xdg_data and xdg_data .. "/trash/" or home .. "/.local/share/Trash/"
	elseif fn.has("macunix") == 1 then
		-- INFO macOS moves files to the icloud trash, if they are deleted from
		-- icloud folder, otherwise they go the user trash folder
		local iCloudPath = home .. "/Library/Mobile Documents/com~apple~CloudDocs"
		local isInICloud = fn.expand("%:p:h"):sub(1, #iCloudPath) == iCloudPath
		trash = isInICloud and iCloudPath .. "/.Trash/" or home .. "/.Trash/"
	else
		-- TODO: support windows
		trash = home .. "/.Trash/"
	end

	-- overwrite trash location, if specified by user
	if opts and opts.trashLocation then
		trash = opts.trashLocation
		if not (trash:find("/$")) then trash = trash .. "/" end -- append "/"
	end

	local currentFile = expand("%:p")
	local filename = expand("%:t")
	local success, errormsg = os.rename(currentFile, trash .. filename)

	if success then
		cmd.bwipeout()
		vim.notify('"' .. filename .. '" deleted.')
	else
		vim.notify("Could not delete file: " .. errormsg, logError)
	end
end

return M
