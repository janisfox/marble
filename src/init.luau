--[[

                                   /$$       /$$          
                                  | $$      | $$          
 /$$$$$$/$$$$   /$$$$$$   /$$$$$$ | $$$$$$$ | $$  /$$$$$$ 
| $$_  $$_  $$ |____  $$ /$$__  $$| $$__  $$| $$ /$$__  $$
| $$ \ $$ \ $$  /$$$$$$$| $$  \__/| $$  \ $$| $$| $$$$$$$$
| $$ | $$ | $$ /$$__  $$| $$      | $$  | $$| $$| $$_____/
| $$ | $$ | $$|  $$$$$$$| $$      | $$$$$$$/| $$|  $$$$$$$
|__/ |__/ |__/ \_______/|__/      |_______/ |__/ \_______/

xlch_studios() 2026 ©
founded by janis (@the_h0lysandwich)

]]--

--// Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")

--// Locals
local isServer = RunService:IsServer()

--// Constants
local DS_USER_AUTH_KEY = "marble_user_auth"
local DS_GROUP_AUTH_KEY = "marble_group_auth"
local DS_ROLE_KEY = "marble_roles"
local MSG_CHANNEL = "marble_sync_%s"

-- Message action types
local ACTION = {
	AUTH_USER = "AUTH_USER",
	AUTH_GROUP = "AUTH_GROUP",
	DEAUTH_USER = "DEAUTH_USER",
	DEAUTH_GROUP = "DEAUTH_GROUP",
	MODIFY_ROLE = "MODIFY_ROLE",
}

--// Internal
local internal = {}

function internal.registerPermission(self, permission: string)
	if typeof(permission) ~= "string" then return end
	if not self.permissions then return end
	if not self.permissions[permission] then
		self.permissions[permission] = true
	end
end

function internal:Signal()
	return Instance.new("BindableEvent")
end

-- Safely update a DataStore key using UpdateAsync for atomicity
function internal.dsUpdate(store: DataStore, key: string, updater: (any) -> any)
	local tries = 0
	local success, err
	repeat
		tries += 1
		success, err = pcall(function()
			store:UpdateAsync(key, updater)
		end)
		if not success then
			warn("[Marble/DS] UpdateAsync failed (attempt " .. tries .. "): " .. tostring(err))
			task.wait(2 ^ tries) -- exponential backoff
		end
	until success or tries >= 3
	return success
end

-- Safely get from a DataStore
function internal.dsGet(store: DataStore, key: string): any
	local tries = 0
	local success, result
	repeat
		tries += 1
		success, result = pcall(function()
			return store:GetAsync(key)
		end)
		if not success then
			warn("[Marble/DS] GetAsync failed (attempt " .. tries .. "): " .. tostring(result))
			task.wait(2 ^ tries)
		end
	until success or tries >= 3
	return success and result or nil
end

-- Publish a cross-server sync message (fire and forget, errors are non-fatal)
function internal.publish(channel: string, payload: {})
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:PublishAsync(channel, payload)
		end)
		if not ok then
			warn("[Marble/Sync] PublishAsync failed: " .. tostring(err))
		end
	end)
end

--// Types
export type ConditionTypes = "any" | number

export type MarbleData = {
	datastore: string?,
	scope: string?,
}

export type RoleData = {
	name: string,
	permissions: {[string]: boolean},
	color: Color3?,
	allowAuthManagement: boolean?,
	datastore: boolean?,
}

--// Globals
local marble = {}
marble.__index = marble
marble.runtimes = {}

function marble.new(key: string, data: MarbleData)
	local self = setmetatable({}, marble)

	self._key = key

	self.authorized = {
		Groups = {} :: {[number]: {roleName: string, rank: number}},
		Users = {} :: {[number]: string},
	}
	self.userRoles = {} :: {[number]: {string}}
	self.roles = {} :: {[string]: {permissions: {[string]: boolean}, color: Color3?, datastore: boolean?}}
	self.permissions = {} :: {[string]: true}

	-- DataStore handles (nil if no datastore configured)
	if data.datastore and isServer then
		local scope = data.scope or "global"
		self._dsUserAuth = DataStoreService:GetDataStore(DS_USER_AUTH_KEY, data.datastore .. "_" .. scope)
		self._dsGroupAuth = DataStoreService:GetDataStore(DS_GROUP_AUTH_KEY, data.datastore .. "_" .. scope)
		self._dsRoles = DataStoreService:GetDataStore(DS_ROLE_KEY, data.datastore .. "_" .. scope)
		self._msgChannel = MSG_CHANNEL:format(key)
	end

	self.userUpdated = internal:Signal()

	marble.runtimes[key] = self

	if isServer then
		self:_initDataStore()
		self:_initMessaging()
		self:_initPlayerHandlers()
	end

	return self
end

function marble.getRuntime(key: string)
	if not isServer then return end
	return marble.runtimes[key]
end

-- Init

-- Load persisted roles and auth entries from DataStore on server start
function marble:_initDataStore()
	if not self._dsRoles then return end

	task.spawn(function()
		-- Load persisted roles
		local savedRoles = internal.dsGet(self._dsRoles, "roles")
		if savedRoles then
			for roleName, roleData in pairs(savedRoles) do
				-- Only load if not already hardcoded
				if not self.roles[roleName] then
					self.roles[roleName] = roleData
					for perm in pairs(roleData.permissions) do
						internal.registerPermission(self, perm)
					end
				end
			end
		end

		-- Load persisted user auths
		local savedUserAuth = internal.dsGet(self._dsUserAuth, "users")
		if savedUserAuth then
			for userId, roleName in pairs(savedUserAuth) do
				userId = tonumber(userId)
				if userId and self.roles[roleName] then
					self.authorized.Users[userId] = roleName
				end
			end
		end

		-- Load persisted group auths
		local savedGroupAuth = internal.dsGet(self._dsGroupAuth, "groups")
		if savedGroupAuth then
			for groupId, entry in pairs(savedGroupAuth) do
				groupId = tonumber(groupId)
				if groupId and self.roles[entry.roleName] then
					self.authorized.Groups[groupId] = entry
				end
			end
		end

		-- Sync roles for players who joined before DS loaded
		for _, player in Players:GetPlayers() do
			self:_resolvePlayerRoles(player)
		end
	end)
end

-- Subscribe to cross-server updates from MessagingService
function marble:_initMessaging()
	if not self._msgChannel then return end

	local ok, err = pcall(function()
		MessagingService:SubscribeAsync(self._msgChannel, function(msg)
			local payload = msg.Data
			if typeof(payload) ~= "table" then return end
			self:_applyRemoteAction(payload)
		end)
	end)

	if not ok then
		warn("[Marble/Sync] SubscribeAsync failed: " .. tostring(err))
	end
end

-- Wire up Players events to resolve roles on join
function marble:_initPlayerHandlers()
	Players.PlayerAdded:Connect(function(player)
		self:_resolvePlayerRoles(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.userRoles[player.UserId] = nil
	end)
end

-- Role resolution

-- Build the in-memory userRoles entry for a player from authorized Users/Groups
function marble:_resolvePlayerRoles(player: Player)
	local uid = player.UserId
	local roles = {}

	-- Direct user auth
	local directRole = self.authorized.Users[uid]
	if directRole and self.roles[directRole] then
		if not table.find(roles, directRole) then
			table.insert(roles, directRole)
		end
	end

	-- Group auth
	for groupId, entry in pairs(self.authorized.Groups) do
		local ok1, inGroup = pcall(function() return player:IsInGroupAsync(groupId) end)
		if not ok1 or not inGroup then continue end

		local meetsRank = true
		if entry.rank then
			local ok2, playerRank = pcall(function() return player:GetRankInGroupAsync(groupId) end)
			meetsRank = ok2 and playerRank >= entry.rank
		end

		if meetsRank then
			local roleName = entry.roleName
			if self.roles[roleName] and not table.find(roles, roleName) then
				table.insert(roles, roleName)
			end
		end
	end

	self.userRoles[uid] = roles
	self.userUpdated:Fire(player)
end

-- Remote action handler (applied on THIS server when a message arrives)

function marble:_applyRemoteAction(payload: {[string]: any})
	local action = payload.action

	if action == ACTION.AUTH_USER then
		local userId, roleName = payload.userId, payload.roleName
		if not self.roles[roleName] then return end
		self.authorized.Users[userId] = roleName
		local player = Players:GetPlayerByUserId(userId)
		if player then self:_resolvePlayerRoles(player) end

	elseif action == ACTION.DEAUTH_USER then
		local userId = payload.userId
		self.authorized.Users[userId] = nil
		self.userRoles[userId] = nil
		local player = Players:GetPlayerByUserId(userId)
		if player then self:_resolvePlayerRoles(player) end

	elseif action == ACTION.AUTH_GROUP then
		local groupId, roleName, rank = payload.groupId, payload.roleName, payload.rank
		if not self.roles[roleName] then return end
		self.authorized.Groups[groupId] = { roleName = roleName, rank = rank }
		for _, player in Players:GetPlayers() do
			self:_resolvePlayerRoles(player)
		end

	elseif action == ACTION.DEAUTH_GROUP then
		local groupId = payload.groupId
		self.authorized.Groups[groupId] = nil
		for _, player in Players:GetPlayers() do
			self:_resolvePlayerRoles(player)
		end

	elseif action == ACTION.MODIFY_ROLE then
		local roleName, permissions = payload.roleName, payload.permissions
		if not self.roles[roleName] then return end
		for perm, val in pairs(permissions) do
			internal.registerPermission(self, perm)
			self.roles[roleName].permissions[perm] = val
		end
		-- Re-resolve all players since their effective permissions changed
		for _, player in Players:GetPlayers() do
			self:_resolvePlayerRoles(player)
		end
	end
end

-- Public API

function marble:registerPermission(perms: string | {string})
	if not isServer then return end
	if typeof(perms) == "string" then
		internal.registerPermission(self, perms)
	elseif typeof(perms) == "table" then
		for _, x in perms do
			internal.registerPermission(self, x)
		end
	end
end

function marble:registerRole(data: RoleData)
	if not isServer then return end
	if typeof(data) ~= "table" then return end
	if typeof(data.name) ~= "string" or data.name == "" then return end
	if typeof(data.permissions) ~= "table" then return end

	local permissionCopy = {}
	for x, y in pairs(data.permissions) do
		if typeof(x) ~= "string" or typeof(y) ~= "boolean" then
			warn("[Marble/registerRole] Invalid permission entry: " .. tostring(x))
			continue
		end
		permissionCopy[x] = y
		internal.registerPermission(self, x)
	end

	self.roles[data.name] = {
		permissions = permissionCopy,
		color = data.color,
		datastore = data.datastore,
		allowAuthManagement = data.allowAuthManagement,
	}

	-- Persist if this role is flagged as datastore-backed
	if data.datastore and self._dsRoles then
		task.spawn(function()
			internal.dsUpdate(self._dsRoles, "roles", function(current)
				current = current or {}
				current[data.name] = {
					permissions = permissionCopy,
					datastore = data.datastore,
					allowAuthManagement = data.allowAuthManagement,
					-- Color3 can't be stored in DataStore; store components instead
					colorR = data.color and data.color.R or nil,
					colorG = data.color and data.color.G or nil,
					colorB = data.color and data.color.B or nil,
				}
				return current
			end)
		end)
		-- No cross-server broadcast needed here: registerRole is called at startup
		-- from code, so all servers will run it themselves.
	end
end

function marble:modifyRole(role: string, newData: RoleData)
	if not isServer then return end
	if not self.roles[role] then
		warn("[Marble/modifyRole] Role '" .. role .. "' is not registered.")
		return
	end

	local permissionCopy = table.clone(self.roles[role].permissions)
	for x, y in pairs(newData.permissions) do
		if typeof(x) ~= "string" or typeof(y) ~= "boolean" or not self.permissions[x] then
			warn("[Marble/modifyRole] Invalid or unregistered permission: " .. tostring(x))
			continue
		end
		permissionCopy[x] = y
	end
	self.roles[role].permissions = permissionCopy

	-- Re-resolve all current players
	for _, player in Players:GetPlayers() do
		self:_resolvePlayerRoles(player)
	end

	-- Persist and broadcast if this role is datastore-backed
	if self.roles[role].datastore and self._dsRoles then
		task.spawn(function()
			internal.dsUpdate(self._dsRoles, "roles", function(current)
				current = current or {}
				if current[role] then
					current[role].permissions = permissionCopy
				end
				return current
			end)
		end)

		internal.publish(self._msgChannel, {
			action = ACTION.MODIFY_ROLE,
			roleName = role,
			permissions = permissionCopy,
		})
	end
end

function marble:auth(_type: "user" | "group", id: number, roleName: string, rank: number?)
	if not isServer then return false end
	if typeof(id) ~= "number" then return false end
	if typeof(roleName) ~= "string" or not self.roles[roleName] then
		warn("[Marble/auth] Role '" .. tostring(roleName) .. "' is not registered.")
		return false
	end

	local roleIsDynamic = self.roles[roleName].datastore == true

	if _type == "user" then
		-- Verify the userId resolves to a real account
		local success, name = pcall(function()
			return Players:GetNameFromUserIdAsync(id)
		end)
		if not success or not name then
			warn("[Marble/auth] Failed to verify userId: " .. tostring(id))
			return false
		end

		self.authorized.Users[id] = roleName

		local player = Players:GetPlayerByUserId(id)
		if player then
			self:_resolvePlayerRoles(player)
		end

		if roleIsDynamic and self._dsUserAuth then
			task.spawn(function()
				internal.dsUpdate(self._dsUserAuth, "users", function(current)
					current = current or {}
					current[tostring(id)] = roleName
					return current
				end)
			end)

			internal.publish(self._msgChannel, {
				action = ACTION.AUTH_USER,
				userId = id,
				roleName = roleName,
			})
		end

		return true

	elseif _type == "group" then
		if rank ~= nil and typeof(rank) ~= "number" then return false end

		self.authorized.Groups[id] = { roleName = roleName, rank = rank or 1 }

		for _, player in Players:GetPlayers() do
			self:_resolvePlayerRoles(player)
		end

		if roleIsDynamic and self._dsGroupAuth then
			task.spawn(function()
				internal.dsUpdate(self._dsGroupAuth, "groups", function(current)
					current = current or {}
					current[tostring(id)] = { roleName = roleName, rank = rank or 1 }
					return current
				end)
			end)

			internal.publish(self._msgChannel, {
				action = ACTION.AUTH_GROUP,
				groupId = id,
				roleName = roleName,
				rank = rank or 1,
			})
		end

		return true
	end

	return false
end

-- Revoke a user or group auth entry
function marble:deauth(_type: "user" | "group", id: number)
	if not isServer then return false end
	if typeof(id) ~= "number" then return false end

	if _type == "user" then
		local roleName = self.authorized.Users[id]
		local roleIsDynamic = roleName and self.roles[roleName] and self.roles[roleName].datastore

		self.authorized.Users[id] = nil
		self.userRoles[id] = nil

		local player = Players:GetPlayerByUserId(id)
		if player then self:_resolvePlayerRoles(player) end

		if roleIsDynamic and self._dsUserAuth then
			task.spawn(function()
				internal.dsUpdate(self._dsUserAuth, "users", function(current)
					current = current or {}
					current[tostring(id)] = nil
					return current
				end)
			end)

			internal.publish(self._msgChannel, {
				action = ACTION.DEAUTH_USER,
				userId = id,
			})
		end

		return true

	elseif _type == "group" then
		local entry = self.authorized.Groups[id]
		local roleIsDynamic = entry and self.roles[entry.roleName] and self.roles[entry.roleName].datastore

		self.authorized.Groups[id] = nil

		for _, player in Players:GetPlayers() do
			self:_resolvePlayerRoles(player)
		end

		if roleIsDynamic and self._dsGroupAuth then
			task.spawn(function()
				internal.dsUpdate(self._dsGroupAuth, "groups", function(current)
					current = current or {}
					current[tostring(id)] = nil
					return current
				end)
			end)

			internal.publish(self._msgChannel, {
				action = ACTION.DEAUTH_GROUP,
				groupId = id,
			})
		end

		return true
	end

	return false
end

function marble:hasPermission(userId: number, permission: string): boolean
	if not isServer then return false end
	if typeof(userId) ~= "number" or typeof(permission) ~= "string" then return false end
	if not self.permissions[permission] then
		warn("[Marble/hasPermission] Permission '" .. permission .. "' is not registered.")
		return false
	end

	local roles = self.userRoles[userId]
	if not roles then return false end

	for _, roleName in roles do
		local role = self.roles[roleName]
		if role and role.permissions[permission] == true then
			return true
		end
	end

	return false
end

return marble