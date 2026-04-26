--[[

                                   /$$       /$$          
                                  | $$      | $$          
 /$$$$$$/$$$$   /$$$$$$   /$$$$$$ | $$$$$$$ | $$  /$$$$$$ 
| $$_  $$_  $$ |____  $$ /$$__  $$| $$__  $$| $$ /$$__  $$
| $$ \ $$ \ $$  /$$$$$$$| $$  \__/| $$  \ $$| $$| $$$$$$$$
| $$ | $$ | $$ /$$__  $$| $$      | $$  | $$| $$| $$_____/
| $$ | $$ | $$|  $$$$$$$| $$      | $$$$$$$/| $$|  $$$$$$$
|__/ |__/ |__/ \_______/|__/      |_______/ |__/ \_______/

Marble Authentication System
xlch_studios() 2026 ©
founded by janis (@the_h0lysandwich)

A robust, scalable role-based authorization system with cross-server support.
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
local DS_RETRY_ATTEMPTS = 3
local DS_RETRY_BACKOFF_BASE = 2

--// Message action types
local ACTION = {
	AUTH_USER = "AUTH_USER",
	AUTH_GROUP = "AUTH_GROUP",
	DEAUTH_USER = "DEAUTH_USER",
	DEAUTH_GROUP = "DEAUTH_GROUP",
	MODIFY_ROLE = "MODIFY_ROLE",
	DEAUTH_ROLE = "DEAUTH_ROLE",
}

--// Internal Utilities
local internal = {}

--[[
	Registers a permission in the permissions dictionary if not already present.
	@param self The Marble runtime instance
	@param permission The permission name to register
]]
function internal.registerPermission(self, permission: string)
	if typeof(permission) ~= "string" or permission == "" then return end
	if not self.permissions then return end
	if not self.permissions[permission] then
		self.permissions[permission] = true
	end
end

--[[
	Creates a BindableEvent signal for event-driven updates.
	@return A new BindableEvent instance
]]
function internal:Signal()
	return Instance.new("BindableEvent")
end

--[[
	Validates that a value is a non-empty string.
	@param value The value to validate
	@param fieldName The name of the field for error messages
	@return true if valid, false otherwise
]]
function internal.validateString(value: any, fieldName: string): boolean
	if typeof(value) ~= "string" or value == "" then
		warn("[Marble] Invalid " .. fieldName .. ": expected non-empty string")
		return false
	end
	return true
end

--[[
	Validates that a value is a positive number.
	@param value The value to validate
	@param fieldName The name of the field for error messages
	@return true if valid, false otherwise
]]
function internal.validateNumber(value: any, fieldName: string): boolean
	if typeof(value) ~= "number" or value < 0 then
		warn("[Marble] Invalid " .. fieldName .. ": expected non-negative number")
		return false
	end
	return true
end

--[[
	Validates that a role exists in the runtime.
	@param self The Marble runtime instance
	@param roleName The role name to check
	@return true if the role exists, false otherwise
]]
function internal.validateRole(self, roleName: string): boolean
	if not self.roles[roleName] then
		warn("[Marble] Role '" .. roleName .. "' is not registered")
		return false
	end
	return true
end

--[[
	Safely updates a DataStore key using UpdateAsync for atomicity with exponential backoff.
	@param store The DataStore instance
	@param key The key to update
	@param updater The update function
	@return true if successful, false otherwise
]]
function internal.dsUpdate(store: DataStore, key: string, updater: (any) -> any): boolean
	local tries = 0
	local success, err
	repeat
		tries += 1
		success, err = pcall(function()
			store:UpdateAsync(key, updater)
		end)
		if not success then
			warn("[Marble/DS] UpdateAsync failed (attempt " .. tries .. "): " .. tostring(err))
			if tries < DS_RETRY_ATTEMPTS then
				task.wait(DS_RETRY_BACKOFF_BASE ^ tries)
			end
		end
	until success or tries >= DS_RETRY_ATTEMPTS
	return success
end

--[[
	Safely gets a value from a DataStore with exponential backoff.
	@param store The DataStore instance
	@param key The key to retrieve
	@return The stored value, or nil if retrieval failed
]]
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
			if tries < DS_RETRY_ATTEMPTS then
				task.wait(DS_RETRY_BACKOFF_BASE ^ tries)
			end
		end
	until success or tries >= DS_RETRY_ATTEMPTS
	return success and result or nil
end

--[[
	Publishes a cross-server sync message asynchronously (fire and forget).
	Non-fatal errors are logged but not propagated.
	@param channel The messaging channel
	@param payload The message payload table
]]
function internal.publish(channel: string, payload: {[string]: any})
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:PublishAsync(channel, game:GetService("HttpService"):JSONEncode(payload))
		end)
		if not ok then
			warn("[Marble/Sync] PublishAsync failed: " .. tostring(err))
		end
	end)
end

--[[
	Encodes a Color3 value for DataStore storage.
	@param color The Color3 to encode, or nil
	@return A table with R, G, B components, or nil
]]
function internal.encodeColor(color: Color3?): {R: number?, G: number?, B: number?}?
	if not color then return nil end
	return { R = color.R, G = color.G, B = color.B }
end

--[[
	Decodes a Color3 from stored components.
	@param data The encoded color data
	@return A Color3, or nil if data is invalid
]]
function internal.decodeColor(data: {R: number?, G: number?, B: number?}?): Color3?
	if not data or typeof(data.R) ~= "number" or typeof(data.G) ~= "number" or typeof(data.B) ~= "number" then
		return nil
	end
	return Color3.new(data.R, data.G, data.B)
end

--// Type Definitions
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

export type Role = {
	permissions: {[string]: boolean},
	color: Color3?,
	datastore: boolean?,
	allowAuthManagement: boolean?,
}

export type GroupAuthEntry = {
	roleName: string,
	rank: number,
}

--// Marble Runtime
local marble = {}
marble.__index = marble
marble.runtimes = {} :: {[string]: any}

--[[
	Creates a new Marble runtime instance.
	@param key A unique identifier for this runtime
	@param data Configuration options (datastore name, scope)
	@return The new Marble runtime instance
]]
function marble.new(key: string, data: MarbleData)
	if typeof(key) ~= "string" or key == "" then
		error("[Marble] key must be a non-empty string")
	end
	if typeof(data) ~= "table" then
		error("[Marble] data must be a table")
	end

	local self = setmetatable({}, marble)

	self._key = key
	self._initialized = false

	--// Authorization tables
	self.authorized = {
		Groups = {} :: {[number]: GroupAuthEntry},
		Users = {} :: {[number]: string},
	}
	self.userRoles = {} :: {[number]: {string}}
	self.roles = {} :: {[string]: Role}
	self.permissions = {} :: {[string]: true}

	--// DataStore initialization (server only)
	if data.datastore and isServer then
		local scope = data.scope or "global"
		if typeof(data.datastore) ~= "string" or data.datastore == "" then
			warn("[Marble] Invalid datastore name, DataStore features disabled")
		else
			self._dsUserAuth = DataStoreService:GetDataStore(DS_USER_AUTH_KEY, data.datastore .. "_" .. scope)
			self._dsGroupAuth = DataStoreService:GetDataStore(DS_GROUP_AUTH_KEY, data.datastore .. "_" .. scope)
			self._dsRoles = DataStoreService:GetDataStore(DS_ROLE_KEY, data.datastore .. "_" .. scope)
			self._msgChannel = MSG_CHANNEL:format(key)
		end
	end

	--// Signal for user role updates
	self.userUpdated = internal:Signal()

	--// Store runtime
	marble.runtimes[key] = self

	if isServer then
		self:_initDataStore()
		self:_initMessaging()
		self:_initPlayerHandlers()
		self._initialized = true
	end

	return self
end

--[[
	Retrieves a runtime instance by key (server only).
	@param key The runtime key
	@return The runtime instance, or nil if not found
]]
function marble.getRuntime(key: string): any?
	if not isServer then return nil end
	return marble.runtimes[key]
end

--// Initialization

--[[
	Loads persisted roles and authorization entries from DataStore on server start.
	Runs asynchronously and handles loading failures gracefully.
]]
function marble:_initDataStore()
	if not self._dsRoles then return end

	task.spawn(function()
		-- Load persisted roles
		local savedRoles = internal.dsGet(self._dsRoles, "roles")
		if savedRoles and typeof(savedRoles) == "table" then
			for roleName, roleData in pairs(savedRoles) do
				if typeof(roleName) == "string" and typeof(roleData) == "table" then
					-- Only load if not already hardcoded
					if not self.roles[roleName] then
						local color = internal.decodeColor(roleData)
						self.roles[roleName] = {
							permissions = roleData.permissions or {},
							color = color,
							datastore = roleData.datastore,
							allowAuthManagement = roleData.allowAuthManagement,
						}
						-- Register all permissions from the loaded role
						if typeof(roleData.permissions) == "table" then
							for perm in pairs(roleData.permissions) do
								internal.registerPermission(self, perm)
							end
						end
					end
				end
			end
		end

		-- Load persisted user authorizations
		local savedUserAuth = internal.dsGet(self._dsUserAuth, "users")
		if savedUserAuth and typeof(savedUserAuth) == "table" then
			for userIdStr, roleName in pairs(savedUserAuth) do
				local userId = tonumber(userIdStr)
				if userId and typeof(roleName) == "string" and self.roles[roleName] then
					self.authorized.Users[userId] = roleName
				end
			end
		end

		-- Load persisted group authorizations
		local savedGroupAuth = internal.dsGet(self._dsGroupAuth, "groups")
		if savedGroupAuth and typeof(savedGroupAuth) == "table" then
			for groupIdStr, entry in pairs(savedGroupAuth) do
				local groupId = tonumber(groupIdStr)
				if groupId and typeof(entry) == "table" and typeof(entry.roleName) == "string" and self.roles[entry.roleName] then
					self.authorized.Groups[groupId] = {
						roleName = entry.roleName,
						rank = typeof(entry.rank) == "number" and entry.rank or 1,
					}
				end
			end
		end

		-- Sync roles for players who joined before DataStore loaded
		for _, player in Players:GetPlayers() do
			self:_resolvePlayerRoles(player)
		end
	end)
end

--[[
	Subscribes to cross-server synchronization messages from MessagingService.
	Handles incoming remote auth/role changes from other servers.
]]
function marble:_initMessaging()
	if not self._msgChannel then return end

	local ok, err = pcall(function()
		MessagingService:SubscribeAsync(self._msgChannel, function(msg)
			if typeof(msg) ~= "table" or typeof(msg.Data) ~= "string" then return end
			local success, payload = pcall(function()
				return game:GetService("HttpService"):JSONDecode(msg.Data)
			end)
			if success and typeof(payload) == "table" then
				self:_applyRemoteAction(payload)
			end
		end)
	end)

	if not ok then
		warn("[Marble/Sync] SubscribeAsync failed: " .. tostring(err))
	end
end

--[[
	Wires up player join/leave event handlers to manage role resolution.
]]
function marble:_initPlayerHandlers()
	Players.PlayerAdded:Connect(function(player)
		self:_resolvePlayerRoles(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.userRoles[player.UserId] = nil
	end)
end

--// Role Resolution

--[[
	Builds the in-memory userRoles entry for a player from authorized Users/Groups.
	Checks both direct user authorizations and group memberships with rank requirements.
	Fires the userUpdated signal after computing roles.
	@param player The player to resolve roles for
]]
function marble:_resolvePlayerRoles(player: Player)
	local uid = player.UserId
	local roles = {}

	-- Direct user authorization
	local directRole = self.authorized.Users[uid]
	if directRole and internal.validateRole(self, directRole) then
		table.insert(roles, directRole)
	end

	-- Group-based authorization
	for groupId, entry in pairs(self.authorized.Groups) do
		if typeof(entry) ~= "table" or typeof(entry.roleName) ~= "string" then continue end

		-- Check if player is in the group
		local ok1, inGroup = pcall(function()
			return player:IsInGroupAsync(groupId)
		end)
		if not ok1 or not inGroup then continue end

		-- Check if player meets the rank requirement
		local meetsRank = true
		if typeof(entry.rank) == "number" and entry.rank > 0 then
			local ok2, playerRank = pcall(function()
				return player:GetRankInGroupAsync(groupId)
			end)
			meetsRank = ok2 and typeof(playerRank) == "number" and playerRank >= entry.rank
		end

		-- Add role if conditions are met
		if meetsRank and self.roles[entry.roleName] and not table.find(roles, entry.roleName) then
			table.insert(roles, entry.roleName)
		end
	end

	self.userRoles[uid] = roles
	self.userUpdated:Fire(player)
end

--// Remote Action Handlers

--[[
	Applies a remote synchronization action received from MessagingService.
	Handles AUTH_USER, DEAUTH_USER, AUTH_GROUP, DEAUTH_GROUP, and MODIFY_ROLE actions.
	@param payload The message payload containing action and parameters
]]
function marble:_applyRemoteAction(payload: {[string]: any})
	if typeof(payload) ~= "table" or typeof(payload.action) ~= "string" then return end

	local action = payload.action

	if action == ACTION.AUTH_USER then
		local userId = payload.userId
		local roleName = payload.roleName
		if typeof(userId) == "number" and internal.validateRole(self, roleName) then
			self.authorized.Users[userId] = roleName
			local player = Players:GetPlayerByUserId(userId)
			if player then
				self:_resolvePlayerRoles(player)
			end
		end

	elseif action == ACTION.DEAUTH_USER then
		local userId = payload.userId
		if typeof(userId) == "number" then
			self.authorized.Users[userId] = nil
			self.userRoles[userId] = nil
			local player = Players:GetPlayerByUserId(userId)
			if player then
				self:_resolvePlayerRoles(player)
			end
		end

	elseif action == ACTION.AUTH_GROUP then
		local groupId = payload.groupId
		local roleName = payload.roleName
		local rank = payload.rank
		if typeof(groupId) == "number" and internal.validateRole(self, roleName) then
			self.authorized.Groups[groupId] = {
				roleName = roleName,
				rank = typeof(rank) == "number" and rank or 1,
			}
			for _, player in Players:GetPlayers() do
				self:_resolvePlayerRoles(player)
			end
		end

	elseif action == ACTION.DEAUTH_GROUP then
		local groupId = payload.groupId
		if typeof(groupId) == "number" then
			self.authorized.Groups[groupId] = nil
			for _, player in Players:GetPlayers() do
				self:_resolvePlayerRoles(player)
			end
		end

	elseif action == ACTION.MODIFY_ROLE then
		local roleName = payload.roleName
		local permissions = payload.permissions
		if internal.validateRole(self, roleName) and typeof(permissions) == "table" then
			for perm, val in pairs(permissions) do
				if typeof(perm) == "string" and typeof(val) == "boolean" then
					internal.registerPermission(self, perm)
					self.roles[roleName].permissions[perm] = val
				end
			end
			-- Re-resolve all players since their effective permissions changed
			for _, player in Players:GetPlayers() do
				self:_resolvePlayerRoles(player)
			end
		end

	elseif action == ACTION.DEAUTH_ROLE then
		local roleName = payload.roleName
		if internal.validateRole(self, roleName) then
			-- Remove all users with this role
			for userId, role in pairs(self.authorized.Users) do
				if role == roleName then
					self.authorized.Users[userId] = nil
					self.userRoles[userId] = nil
				end
			end
			-- Remove all groups with this role
			for groupId, entry in pairs(self.authorized.Groups) do
				if entry.roleName == roleName then
					self.authorized.Groups[groupId] = nil
				end
			end
			-- Re-resolve all players
			for _, player in Players:GetPlayers() do
				self:_resolvePlayerRoles(player)
			end
		end
	end
end

--// Public API

--// Public API - Permissions

--[[
	Registers one or more permissions in the system.
	Permissions must be registered before they can be used in roles.
	@param perms A string or array of permission names to register
]]
function marble:registerPermission(perms: string | {string})
	if not isServer then return end
	if typeof(perms) == "string" then
		internal.registerPermission(self, perms)
	elseif typeof(perms) == "table" then
		for _, perm in ipairs(perms) do
			if typeof(perm) == "string" then
				internal.registerPermission(self, perm)
			end
		end
	end
end

--// Public API - Role Management

--[[
	Registers a new role in the system.
	Roles can have multiple permissions and optional metadata (color, management flags).
	@param data The role data (name, permissions, optional color/flags)
	@return true if successful, false otherwise
]]
function marble:registerRole(data: RoleData): boolean
	if not isServer then return false end
	if not internal.validateString(data.name or "", "role name") then return false end
	if typeof(data.permissions) ~= "table" then
		warn("[Marble] Role permissions must be a table")
		return false
	end

	-- Validate and copy permissions
	local permissionCopy = {}
	for perm, val in pairs(data.permissions) do
		if typeof(perm) ~= "string" or typeof(val) ~= "boolean" then
			warn("[Marble] Invalid permission entry: " .. tostring(perm))
			continue
		end
		permissionCopy[perm] = val
		internal.registerPermission(self, perm)
	end

	-- Store role
	self.roles[data.name] = {
		permissions = permissionCopy,
		color = data.color,
		datastore = data.datastore == true,
		allowAuthManagement = data.allowAuthManagement == true,
	}

	-- Persist if flagged as datastore-backed
	if data.datastore and self._dsRoles then
		task.spawn(function()
			internal.dsUpdate(self._dsRoles, "roles", function(current)
				current = current or {}
				current[data.name] = {
					permissions = permissionCopy,
					datastore = true,
					allowAuthManagement = data.allowAuthManagement,
					color = internal.encodeColor(data.color),
				}
				return current
			end)
		end)
	end

	return true
end

--[[
	Modifies permissions of an existing role.
	Can only modify permissions that are already registered.
	Re-resolves all connected players after modification.
	@param roleName The role to modify
	@param newPermissions Table of permission updates
	@return true if successful, false otherwise
]]
function marble:modifyRole(roleName: string, newPermissions: {[string]: boolean}): boolean
	if not isServer then return false end
	if not internal.validateRole(self, roleName) then return false end
	if typeof(newPermissions) ~= "table" then
		warn("[Marble] newPermissions must be a table")
		return false
	end

	-- Validate and apply permission changes
	local role = self.roles[roleName]
	local permissionCopy = table.clone(role.permissions)
	for perm, val in pairs(newPermissions) do
		if typeof(perm) ~= "string" or typeof(val) ~= "boolean" then
			warn("[Marble] Invalid permission: " .. tostring(perm))
			continue
		end
		if not self.permissions[perm] then
			warn("[Marble] Permission not registered: " .. tostring(perm))
			continue
		end
		permissionCopy[perm] = val
	end
	role.permissions = permissionCopy

	-- Re-resolve all players immediately
	for _, player in Players:GetPlayers() do
		self:_resolvePlayerRoles(player)
	end

	-- Persist and broadcast if datastore-backed
	if role.datastore and self._dsRoles then
		task.spawn(function()
			internal.dsUpdate(self._dsRoles, "roles", function(current)
				current = current or {}
				if current[roleName] then
					current[roleName].permissions = permissionCopy
				end
				return current
			end)
		end)

		internal.publish(self._msgChannel, {
			action = ACTION.MODIFY_ROLE,
			roleName = roleName,
			permissions = permissionCopy,
		})
	end

	return true
end

--// Public API - Authorization

--[[
	Authorizes a user or group to receive a specific role.
	Validates that the role exists and the ID is valid.
	@param authType Either "user" or "group"
	@param id The user ID or group ID
	@param roleName The role to grant
	@param rank (Optional) Minimum group rank required (for group auth)
	@return true if successful, false otherwise
]]
function marble:auth(authType: "user" | "group", id: number, roleName: string, rank: number?): boolean
	if not isServer then return false end
	if not internal.validateNumber(id, "id") then return false end
	if not internal.validateRole(self, roleName) then return false end
	if rank ~= nil and (typeof(rank) ~= "number" or rank < 0) then
		warn("[Marble] rank must be a non-negative number")
		return false
	end

	local roleIsDynamic = self.roles[roleName].datastore

	if authType == "user" then
		-- Verify userId is valid
		local success, name = pcall(function()
			return Players:GetNameFromUserIdAsync(id)
		end)
		if not success or not name then
			warn("[Marble] Failed to verify user ID: " .. tostring(id))
			return false
		end

		self.authorized.Users[id] = roleName

		-- Resolve role for currently connected player
		local player = Players:GetPlayerByUserId(id)
		if player then
			self:_resolvePlayerRoles(player)
		end

		-- Persist and sync if dynamic
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

	elseif authType == "group" then
		self.authorized.Groups[id] = {
			roleName = roleName,
			rank = rank or 0,
		}

		-- Re-resolve all players to check group membership
		for _, player in Players:GetPlayers() do
			self:_resolvePlayerRoles(player)
		end

		-- Persist and sync if dynamic
		if roleIsDynamic and self._dsGroupAuth then
			task.spawn(function()
				internal.dsUpdate(self._dsGroupAuth, "groups", function(current)
					current = current or {}
					current[tostring(id)] = {
						roleName = roleName,
						rank = rank or 0,
					}
					return current
				end)
			end)

			internal.publish(self._msgChannel, {
				action = ACTION.AUTH_GROUP,
				groupId = id,
				roleName = roleName,
				rank = rank or 0,
			})
		end

		return true
	end

	return false
end

--[[
	Revokes authorization for a user or group.
	@param authType Either "user" or "group"
	@param id The user ID or group ID to revoke
	@return true if successful, false otherwise
]]
function marble:deauth(authType: "user" | "group", id: number): boolean
	if not isServer then return false end
	if not internal.validateNumber(id, "id") then return false end

	if authType == "user" then
		local roleName = self.authorized.Users[id]
		local roleIsDynamic = roleName and self.roles[roleName] and self.roles[roleName].datastore

		self.authorized.Users[id] = nil
		self.userRoles[id] = nil

		-- Resolve for currently connected player
		local player = Players:GetPlayerByUserId(id)
		if player then
			self:_resolvePlayerRoles(player)
		end

		-- Persist and sync if dynamic
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

	elseif authType == "group" then
		local entry = self.authorized.Groups[id]
		local roleIsDynamic = entry and self.roles[entry.roleName] and self.roles[entry.roleName].datastore

		self.authorized.Groups[id] = nil

		-- Re-resolve all players
		for _, player in Players:GetPlayers() do
			self:_resolvePlayerRoles(player)
		end

		-- Persist and sync if dynamic
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

--[[
	Revokes all users and groups authorized with a specific role.
	Useful for removing access when a role is deleted or compromised.
	@param roleName The role to deauthorize
	@return The number of entries removed
]]
function marble:deauthRole(roleName: string): number
	if not isServer then return 0 end
	if not internal.validateRole(self, roleName) then return 0 end

	local removed = 0
	local roleIsDynamic = self.roles[roleName].datastore

	-- Remove all users with this role
	for userId, role in pairs(self.authorized.Users) do
		if role == roleName then
			self.authorized.Users[userId] = nil
			self.userRoles[userId] = nil
			removed += 1
		end
	end

	-- Remove all groups with this role
	for groupId, entry in pairs(self.authorized.Groups) do
		if entry.roleName == roleName then
			self.authorized.Groups[groupId] = nil
			removed += 1
		end
	end

	-- Re-resolve all players
	for _, player in Players:GetPlayers() do
		self:_resolvePlayerRoles(player)
	end

	-- Sync if dynamic
	if roleIsDynamic and self._msgChannel then
		internal.publish(self._msgChannel, {
			action = ACTION.DEAUTH_ROLE,
			roleName = roleName,
		})
	end

	return removed
end

--// Public API - Permission Checking

--[[
	Checks if a user has a specific permission.
	Looks through all roles assigned to the user.
	@param userId The user ID to check
	@param permission The permission name
	@return true if the user has the permission, false otherwise
]]
function marble:hasPermission(userId: number, permission: string): boolean
	if not isServer then return false end
	if not internal.validateNumber(userId, "userId") then return false end
	if not internal.validateString(permission, "permission") then return false end
	if not self.permissions[permission] then
		warn("[Marble] Permission not registered: " .. permission)
		return false
	end

	local roles = self.userRoles[userId]
	if not roles or #roles == 0 then return false end

	for _, roleName in ipairs(roles) do
		local role = self.roles[roleName]
		if role and role.permissions[permission] == true then
			return true
		end
	end

	return false
end

--[[
	Gets all roles assigned to a user.
	@param userId The user ID
	@return Array of role names, or empty array if user has no roles
]]
function marble:getUserRoles(userId: number): {string}
	if not isServer then return {} end
	if not internal.validateNumber(userId, "userId") then return {} end
	return self.userRoles[userId] or {}
end

--[[
	Gets all permissions for a user across all their roles.
	@param userId The user ID
	@return Table mapping permission names to true
]]
function marble:getUserPermissions(userId: number): {[string]: boolean}
	if not isServer then return {} end
	if not internal.validateNumber(userId, "userId") then return {} end

	local permissions = {}
	local roles = self.userRoles[userId]
	if not roles then return permissions end

	for _, roleName in ipairs(roles) do
		local role = self.roles[roleName]
		if role then
			for perm, val in pairs(role.permissions) do
				if val then permissions[perm] = true end
			end
		end
	end

	return permissions
end

--// Public API - Queries

--[[
	Gets all users authorized with a specific role.
	@param roleName The role to query
	@return Array of user IDs with that role
]]
function marble:getAuthorizedUsers(roleName: string): {number}
	if not isServer then return {} end
	if not internal.validateRole(self, roleName) then return {} end

	local users = {}
	for userId, role in pairs(self.authorized.Users) do
		if role == roleName then
			table.insert(users, userId)
		end
	end
	return users
end

--[[
	Gets all groups authorized with a specific role.
	@param roleName The role to query
	@return Array of {groupId, rank} pairs
]]
function marble:getAuthorizedGroups(roleName: string): {{groupId: number, rank: number}}
	if not isServer then return {} end
	if not internal.validateRole(self, roleName) then return {} end

	local groups = {}
	for groupId, entry in pairs(self.authorized.Groups) do
		if entry.roleName == roleName then
			table.insert(groups, { groupId = groupId, rank = entry.rank })
		end
	end
	return groups
end

--[[
	Gets a specific role's data.
	@param roleName The role name
	@return The role data, or nil if not found
]]
function marble:getRole(roleName: string): Role?
	if not isServer then return nil end
	if not internal.validateRole(self, roleName) then return nil end
	return self.roles[roleName]
end

--[[
	Gets all registered roles.
	@return Table mapping role names to role data
]]
function marble:getAllRoles(): {[string]: Role}
	if not isServer then return {} end
	return table.clone(self.roles)
end

--[[
	Gets all registered permissions.
	@return Array of permission names
]]
function marble:getAllPermissions(): {string}
	if not isServer then return {} end
	local perms = {}
	for perm in pairs(self.permissions) do
		table.insert(perms, perm)
	end
	table.sort(perms)
	return perms
end

return marble