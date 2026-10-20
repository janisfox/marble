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
local GroupService = game:GetService("GroupService")

--// Locals
local isServer = RunService:IsServer()

--// Constants
local DS_USER_AUTH_KEY = "marble_user_auth"
local DS_GROUP_AUTH_KEY = "marble_group_auth"
local DS_ROLE_KEY = "marble_roles"
local MSG_CHANNEL = "marble_sync_%s"
local DS_RETRY_ATTEMPTS = 3
local DS_RETRY_BACKOFF_BASE = 2
local DEFAULT_PRIORITY = 0

--// Message action types
local ACTION = {
	AUTH_USER = "AUTH_USER",
	AUTH_GROUP = "AUTH_GROUP",
	DEAUTH_USER = "DEAUTH_USER",
	DEAUTH_GROUP = "DEAUTH_GROUP",
	DEAUTH_GROUP_ROLE = "DEAUTH_GROUP_ROLE",
	REGISTER_ROLE = "REGISTER_ROLE",
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
	Validates that a value is a finite, non-negative number.
	NaN and infinities are rejected since they cannot be used as table keys
	(NaN) or meaningful IDs/ranks.
	@param value The value to validate
	@param fieldName The name of the field for error messages
	@return true if valid, false otherwise
]]
function internal.validateNumber(value: any, fieldName: string): boolean
	if typeof(value) ~= "number" or value ~= value or value == math.huge or value < 0 then
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
	if typeof(roleName) ~= "string" or not self.roles[roleName] then
		warn("[Marble] Role '" .. tostring(roleName) .. "' is not registered")
		return false
	end
	return true
end

--[[
	Normalizes a priority value, falling back to the default when unusable.
	@param value The raw priority value
	@return A finite number usable for ordering
]]
function internal.normalizePriority(value: any): number
	if typeof(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return DEFAULT_PRIORITY
	end
	return value
end

--[[
	Returns the priority of a registered role, or the default if unknown.
	@param self The Marble runtime instance
	@param roleName The role name
	@return The role's priority
]]
function internal.priorityOf(self, roleName: string): number
	local role = self.roles[roleName]
	return role and internal.normalizePriority(role.priority) or DEFAULT_PRIORITY
end

--[[
	Determines whether role A outranks role B.
	Higher priority wins; ties fall back to the higher required rank, then
	alphabetical order so resolution stays deterministic across servers.
	@param self The Marble runtime instance
	@param roleA The challenging role name
	@param rankA The group rank requirement backing roleA (0 when not group-based)
	@param roleB The incumbent role name
	@param rankB The group rank requirement backing roleB (0 when not group-based)
	@return true if roleA should win over roleB
]]
function internal.outranks(self, roleA: string, rankA: number, roleB: string, rankB: number): boolean
	local pA, pB = internal.priorityOf(self, roleA), internal.priorityOf(self, roleB)
	if pA ~= pB then return pA > pB end
	if rankA ~= rankB then return rankA > rankB end
	return roleA < roleB
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
	if not success then return nil end
	return result
end

--[[
	Publishes a cross-server sync message asynchronously (fire and forget).
	Payloads are sent as tables; MessagingService serializes them natively,
	so no manual JSON encoding is required. Non-fatal errors are logged.
	@param channel The messaging channel
	@param payload The message payload table
]]
function internal.publish(channel: string?, payload: {[string]: any})
	if not channel then return end
	task.spawn(function()
		local ok, err = pcall(function()
			MessagingService:PublishAsync(channel, payload)
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
	if typeof(data) ~= "table" or typeof(data.R) ~= "number" or typeof(data.G) ~= "number" or typeof(data.B) ~= "number" then
		return nil
	end
	return Color3.new(data.R, data.G, data.B)
end

--[[
	Reads a user's effective rank in a group via GroupService:GetRolesInGroupAsync,
	which supersedes the deprecated Player:GetRankInGroup(Async)/GetRoleInGroup(Async)
	family. Roblox supports multi-role group membership, so a user may hold several
	roles at once and the older methods return an arbitrary one of them; the highest
	rank is what counts here.
	Members holding only the base member role report an empty Roles array, so they
	fall back to rank 1 (the lowest rank a member can have).
	Results are cached per user and group by the engine, so repeated calls are cheap.
	@param userId The user to query
	@param groupId The group to query
	@return The user's highest rank in the group, or 0 if they are not a member
]]
function internal.groupRank(userId: number, groupId: number): number
	local ok, result = pcall(function()
		return GroupService:GetRolesInGroupAsync(userId, groupId)
	end)
	if not ok then
		warn("[Marble/Group] GetRolesInGroupAsync failed for group " .. tostring(groupId) .. ": " .. tostring(result))
		return 0
	end
	if typeof(result) ~= "table" or not result.IsMember then return 0 end

	local highest = 1
	if typeof(result.Roles) == "table" then
		for _, role in result.Roles do
			if typeof(role) == "table" and typeof(role.Rank) == "number" and role.Rank > highest then
				highest = role.Rank
			end
		end
	end
	return highest
end

--[[
	Normalizes a stored/received group entry into the multi-role binding map.
	Accepts both the current { [roleName] = minRank } shape and the legacy
	single-role { roleName = ..., rank = ... } shape for backwards compatibility.
	@param entry The raw group entry
	@return A binding map, or nil if the entry is unusable
]]
function internal.normalizeGroupEntry(entry: any): {[string]: number}?
	if typeof(entry) ~= "table" then return nil end

	-- Legacy single-role entry
	if typeof(entry.roleName) == "string" then
		return { [entry.roleName] = typeof(entry.rank) == "number" and entry.rank or 0 }
	end

	local bindings = {}
	local any = false
	for roleName, minRank in entry do
		if typeof(roleName) == "string" and typeof(minRank) == "number" then
			bindings[roleName] = math.max(minRank, 0)
			any = true
		end
	end
	return any and bindings or nil
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
	priority: number?,
	allowAuthManagement: boolean?,
	datastore: boolean?,
}

export type Role = {
	permissions: {[string]: boolean},
	color: Color3?,
	priority: number,
	datastore: boolean?,
	allowAuthManagement: boolean?,
}

export type RoleChanges = {
	permissions: {[string]: boolean}?,
	color: Color3?,
	priority: number?,
}

--// A group may grant several roles, each gated behind a minimum group rank.
--// The highest-priority role the player qualifies for is the one applied.
export type GroupAuthEntry = {[string]: number}

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
	self._ready = false
	self._connections = {} :: {RBXScriptConnection}
	self.onReady = internal:Signal()

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
	else
		-- Client runtimes hold no state to load, so they are ready right away
		self:_markReady()
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
	Marks the runtime as ready and wakes anything waiting on waitUntilReady.
	Safe to call multiple times.
]]
function marble:_markReady()
	if self._ready then return end
	self._ready = true
	self.onReady:Fire()
end

--[[
	Loads persisted roles and authorization entries from DataStore on server start.
	Runs asynchronously and handles loading failures gracefully.
	When no DataStore is configured the runtime becomes ready immediately.
]]
function marble:_initDataStore()
	if not self._dsRoles then
		self:_markReady()
		return
	end

	task.spawn(function()
		-- Load persisted roles
		local savedRoles = internal.dsGet(self._dsRoles, "roles")
		if typeof(savedRoles) == "table" then
			for roleName, roleData in savedRoles do
				if typeof(roleName) == "string" and typeof(roleData) == "table" then
					-- Only load if not already hardcoded
					if not self.roles[roleName] then
						self.roles[roleName] = {
							permissions = typeof(roleData.permissions) == "table" and roleData.permissions or {},
							color = internal.decodeColor(roleData.color),
							priority = internal.normalizePriority(roleData.priority),
							datastore = roleData.datastore,
							allowAuthManagement = roleData.allowAuthManagement,
						}
						-- Register all permissions from the loaded role
						if typeof(roleData.permissions) == "table" then
							for perm in roleData.permissions do
								internal.registerPermission(self, perm)
							end
						end
					end
				end
			end
		end

		-- Load persisted user authorizations. Entries set in memory while loading
		-- (by code or another server) are newer than the saved ones, so they win.
		local savedUserAuth = internal.dsGet(self._dsUserAuth, "users")
		if typeof(savedUserAuth) == "table" then
			for userIdStr, roleName in savedUserAuth do
				local userId = tonumber(userIdStr)
				if userId and typeof(roleName) == "string" and self.authorized.Users[userId] == nil then
					-- Store even if unregistered; role may be registered later in code
					self.authorized.Users[userId] = roleName
				end
			end
		end

		-- Load persisted group authorizations (legacy single-role entries are migrated).
		-- Saved bindings are merged into any the group already has in memory.
		local savedGroupAuth = internal.dsGet(self._dsGroupAuth, "groups")
		if typeof(savedGroupAuth) == "table" then
			for groupIdStr, entry in savedGroupAuth do
				local groupId = tonumber(groupIdStr)
				local saved = groupId and internal.normalizeGroupEntry(entry)
				if saved then
					local bindings = self.authorized.Groups[groupId] or {}
					for roleName, minRank in saved do
						if bindings[roleName] == nil then
							bindings[roleName] = minRank
						end
					end
					self.authorized.Groups[groupId] = bindings
				end
			end
		end

		-- Sync roles for players who joined before DataStore loaded
		self:_resolveAllPlayers()

		self:_markReady()
	end)
end

--[[
	Subscribes to cross-server synchronization messages from MessagingService.
	Handles incoming remote auth/role changes from other servers.
]]
function marble:_initMessaging()
	if not self._msgChannel then return end

	local ok, result = pcall(function()
		return MessagingService:SubscribeAsync(self._msgChannel, function(msg)
			if typeof(msg) ~= "table" or typeof(msg.Data) ~= "table" then return end
			self:_applyRemoteAction(msg.Data)
		end)
	end)

	if ok then
		self._msgConnection = result
	else
		warn("[Marble/Sync] SubscribeAsync failed: " .. tostring(result))
	end
end

--[[
	Wires up player join/leave event handlers to manage role resolution.
	Players already in the server when the runtime is created are resolved too.
]]
function marble:_initPlayerHandlers()
	table.insert(self._connections, Players.PlayerAdded:Connect(function(player)
		self:_resolvePlayerRoles(player)
	end))

	table.insert(self._connections, Players.PlayerRemoving:Connect(function(player)
		self.userRoles[player.UserId] = nil
	end))

	-- Cover players that joined before this runtime existed. Resolution hits
	-- GroupService and yields, so it must not block runtime construction.
	task.spawn(function()
		self:_resolveAllPlayers()
	end)
end

--// Role Resolution

--[[
	Re-resolves roles for every player currently in the server.
]]
function marble:_resolveAllPlayers()
	for _, player in Players:GetPlayers() do
		self:_resolvePlayerRoles(player)
	end
end

--[[
	Builds the in-memory userRoles entry for a player from authorized Users/Groups.
	A group may bind several roles behind different rank requirements; only the
	highest-priority role the player qualifies for in that group is applied.
	The resulting list is ordered from highest to lowest priority.
	Fires the userUpdated signal after computing roles.
	@param player The player to resolve roles for
]]
function marble:_resolvePlayerRoles(player: Player)
	local uid = player.UserId
	local roles = {}

	-- Direct user authorization
	local directRole = self.authorized.Users[uid]
	if directRole and self.roles[directRole] then
		table.insert(roles, directRole)
	end

	-- Group-based authorization: one winning role per group
	for groupId, bindings in self.authorized.Groups do
		if typeof(bindings) ~= "table" then continue end

		-- Highest of the player's roles in the group; 0 means they are not a member
		local playerRank = internal.groupRank(uid, groupId)
		if playerRank <= 0 then continue end

		-- Pick the highest role the player qualifies for within this group
		local bestRole, bestRank = nil, 0
		for roleName, minRank in bindings do
			if typeof(roleName) ~= "string" or typeof(minRank) ~= "number" then continue end
			if not self.roles[roleName] then continue end
			if playerRank < minRank then continue end

			if not bestRole or internal.outranks(self, roleName, minRank, bestRole, bestRank) then
				bestRole, bestRank = roleName, minRank
			end
		end

		if bestRole and not table.find(roles, bestRole) then
			table.insert(roles, bestRole)
		end
	end

	-- Highest priority first, so lookups short-circuit on the strongest role
	table.sort(roles, function(a, b)
		return internal.outranks(self, a, 0, b, 0)
	end)

	self.userRoles[uid] = roles
	self.userUpdated:Fire(player)
end

--// Remote Action Handlers

--[[
	Applies a remote synchronization action received from MessagingService.
	Handles AUTH_USER, DEAUTH_USER, AUTH_GROUP, DEAUTH_GROUP, DEAUTH_GROUP_ROLE,
	REGISTER_ROLE, MODIFY_ROLE and DEAUTH_ROLE actions.
	@param payload The message payload containing action and parameters
]]
function marble:_applyRemoteAction(payload: {[string]: any})
	if typeof(payload) ~= "table" or typeof(payload.action) ~= "string" then return end

	local action = payload.action

	-- Auth actions are stored even when the role is not registered here yet,
	-- matching how saved authorizations load. Resolution skips unknown roles
	-- until the role arrives (via REGISTER_ROLE, code, or the next load).
	if action == ACTION.AUTH_USER then
		local userId = payload.userId
		local roleName = payload.roleName
		if typeof(userId) == "number" and typeof(roleName) == "string" then
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
		if typeof(groupId) == "number" and typeof(roleName) == "string" then
			local bindings = self.authorized.Groups[groupId] or {}
			bindings[roleName] = typeof(rank) == "number" and math.max(rank, 0) or 0
			self.authorized.Groups[groupId] = bindings
			self:_resolveAllPlayers()
		end

	elseif action == ACTION.DEAUTH_GROUP then
		local groupId = payload.groupId
		if typeof(groupId) == "number" then
			self.authorized.Groups[groupId] = nil
			self:_resolveAllPlayers()
		end

	elseif action == ACTION.DEAUTH_GROUP_ROLE then
		local groupId = payload.groupId
		local roleName = payload.roleName
		local bindings = typeof(groupId) == "number" and self.authorized.Groups[groupId]
		if bindings and typeof(roleName) == "string" then
			bindings[roleName] = nil
			if next(bindings) == nil then
				self.authorized.Groups[groupId] = nil
			end
			self:_resolveAllPlayers()
		end

	elseif action == ACTION.REGISTER_ROLE then
		local roleName = payload.roleName
		if typeof(roleName) ~= "string" or roleName == "" then return end

		-- Roles defined in this server's code take precedence, as on load
		local existing = self.roles[roleName]
		if existing and not existing.datastore then return end

		local permissions = {}
		if typeof(payload.permissions) == "table" then
			for perm, val in payload.permissions do
				if typeof(perm) == "string" and typeof(val) == "boolean" then
					internal.registerPermission(self, perm)
					permissions[perm] = val
				end
			end
		end

		self.roles[roleName] = {
			permissions = permissions,
			color = internal.decodeColor(payload.color),
			priority = internal.normalizePriority(payload.priority),
			datastore = true,
			allowAuthManagement = payload.allowAuthManagement == true,
		}

		-- Authorizations for this role may have arrived before the role did
		self:_resolveAllPlayers()

	elseif action == ACTION.MODIFY_ROLE then
		local roleName = payload.roleName
		if internal.validateRole(self, roleName) then
			local role = self.roles[roleName]
			if typeof(payload.permissions) == "table" then
				for perm, val in payload.permissions do
					if typeof(perm) == "string" and typeof(val) == "boolean" then
						internal.registerPermission(self, perm)
						role.permissions[perm] = val
					end
				end
			end
			if typeof(payload.priority) == "number" then
				role.priority = internal.normalizePriority(payload.priority)
			end
			local color = internal.decodeColor(payload.color)
			if color then
				role.color = color
			end
			-- Re-resolve all players since their effective permissions/order changed
			self:_resolveAllPlayers()
		end

	elseif action == ACTION.DEAUTH_ROLE then
		local roleName = payload.roleName
		-- Strip even if the role is unknown here, since its assignments may not be
		if typeof(roleName) == "string" then
			self:_stripRole(roleName)
			self:_resolveAllPlayers()
		end
	end
end

--[[
	Removes every user and group binding pointing at a role (local state only).
	@param roleName The role to strip
	@return The number of entries removed
]]
function marble:_stripRole(roleName: string): number
	local removed = 0

	-- Remove all users with this role
	for userId, role in self.authorized.Users do
		if role == roleName then
			self.authorized.Users[userId] = nil
			self.userRoles[userId] = nil
			removed += 1
		end
	end

	-- Remove the role from every group that binds it
	for groupId, bindings in self.authorized.Groups do
		if typeof(bindings) == "table" and bindings[roleName] ~= nil then
			bindings[roleName] = nil
			removed += 1
			if next(bindings) == nil then
				self.authorized.Groups[groupId] = nil
			end
		end
	end

	return removed
end

--// Public API

--[[
	Waits until the Datastore of the Authentication table finished loading.
]]
function marble:waitUntilReady()
	if self._ready then return end
	self.onReady.Event:Wait()
end

--[[
	Tears down a runtime: disconnects handlers, releases signals and unregisters
	it from the runtime table. The instance must not be used afterwards.
]]
function marble:destroy()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)

	if self._msgConnection then
		pcall(function()
			self._msgConnection:Disconnect()
		end)
		self._msgConnection = nil
	end

	if marble.runtimes[self._key] == self then
		marble.runtimes[self._key] = nil
	end

	self.onReady:Destroy()
	self.userUpdated:Destroy()
	self._initialized = false
end

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
		for _, perm in perms do
			if typeof(perm) == "string" then
				internal.registerPermission(self, perm)
			end
		end
	end
end

--// Public API - Role Management

--[[
	Registers a new role in the system.
	Roles can have multiple permissions and optional metadata (color, priority,
	management flags). Priority is purely descriptive data like color, but it is
	also what decides which role wins when several apply to the same player.
	@param data The role data (name, permissions, optional color/priority/flags)
	@return true if successful, false otherwise
]]
function marble:registerRole(data: RoleData): boolean
	if not isServer then return false end
	if typeof(data) ~= "table" then
		warn("[Marble] Role data must be a table")
		return false
	end
	if not internal.validateString(data.name or "", "role name") then return false end
	if typeof(data.permissions) ~= "table" then
		warn("[Marble] Role permissions must be a table")
		return false
	end
	if data.priority ~= nil and typeof(data.priority) ~= "number" then
		warn("[Marble] Role priority must be a number")
		return false
	end

	-- Validate and copy permissions
	local permissionCopy = {}
	for perm, val in data.permissions do
		if typeof(perm) ~= "string" or typeof(val) ~= "boolean" then
			warn("[Marble] Invalid permission entry: " .. tostring(perm))
			continue
		end
		permissionCopy[perm] = val
		internal.registerPermission(self, perm)
	end

	local priority = internal.normalizePriority(data.priority)

	-- Store role
	self.roles[data.name] = {
		permissions = permissionCopy,
		color = data.color,
		priority = priority,
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
					priority = priority,
				}
				return current
			end)
		end)

		-- Other servers only load saved roles on startup, so tell them now
		internal.publish(self._msgChannel, {
			action = ACTION.REGISTER_ROLE,
			roleName = data.name,
			permissions = permissionCopy,
			color = internal.encodeColor(data.color),
			priority = priority,
			allowAuthManagement = data.allowAuthManagement == true,
		})
	end

	-- Late-registered roles may unlock authorizations stored before they existed.
	-- Spawned so registering a role never yields on group lookups.
	task.spawn(function()
		self:_resolveAllPlayers()
	end)

	return true
end

--[[
	Modifies an existing role.
	Accepts either a plain permissions map (legacy form) or a changes table with
	optional `permissions`, `color` and `priority` fields. Only permissions that
	are already registered can be modified.
	Re-resolves all connected players after modification.
	@param roleName The role to modify
	@param changes Permission updates, or a table of role changes
	@return true if successful, false otherwise
]]
function marble:modifyRole(roleName: string, changes: {[string]: boolean} | RoleChanges): boolean
	if not isServer then return false end
	if not internal.validateRole(self, roleName) then return false end
	if typeof(changes) ~= "table" then
		warn("[Marble] changes must be a table")
		return false
	end

	-- Distinguish the changes-table form from the legacy permissions-map form
	local isChangeSet = typeof(changes.permissions) == "table" or typeof(changes.color) == "Color3" or typeof(changes.priority) == "number"
	local newPermissions = isChangeSet and changes.permissions or changes
	local newColor = isChangeSet and changes.color or nil
	local newPriority = isChangeSet and changes.priority or nil

	local role = self.roles[roleName]

	-- Validate and apply permission changes
	local permissionCopy = table.clone(role.permissions)
	if typeof(newPermissions) == "table" then
		for perm, val in newPermissions do
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
	end
	role.permissions = permissionCopy

	-- Apply cosmetic/ordering metadata
	if newColor ~= nil then
		role.color = newColor
	end
	if newPriority ~= nil then
		role.priority = internal.normalizePriority(newPriority)
	end

	-- Re-resolve all players immediately
	self:_resolveAllPlayers()

	-- Persist and broadcast if datastore-backed
	if role.datastore and self._dsRoles then
		local storedColor = internal.encodeColor(role.color)
		local storedPriority = role.priority

		task.spawn(function()
			internal.dsUpdate(self._dsRoles, "roles", function(current)
				current = current or {}
				if current[roleName] then
					current[roleName].permissions = permissionCopy
					current[roleName].color = storedColor
					current[roleName].priority = storedPriority
				end
				return current
			end)
		end)

		internal.publish(self._msgChannel, {
			action = ACTION.MODIFY_ROLE,
			roleName = roleName,
			permissions = permissionCopy,
			color = storedColor,
			priority = storedPriority,
		})
	end

	return true
end

--// Public API - Authorization

--[[
	Authorizes a user or group to receive a specific role.
	Group authorizations are additive: a group can bind several roles, each with
	its own minimum rank, and a player receives the highest-priority role they
	qualify for. Re-authorizing the same role on a group updates its rank.
	@param authType Either "user" or "group"
	@param id The user ID or group ID
	@param roleName The role to grant
	@param rank (Optional) Minimum group rank required (for group auth)
	@param datastore (Optional) Persist and broadcast this authorization
	@return true if successful, false otherwise
]]
function marble:auth(authType: "user" | "group", id: number, roleName: string, rank: number?, datastore: boolean?): boolean
	if not isServer then return false end
	if not internal.validateNumber(id, "id") then return false end
	if not internal.validateRole(self, roleName) then return false end
	if rank ~= nil and not internal.validateNumber(rank, "rank") then return false end

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
		if datastore and self._dsUserAuth then
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
		local minRank = rank or 0
		local bindings = self.authorized.Groups[id] or {}
		bindings[roleName] = minRank
		self.authorized.Groups[id] = bindings

		-- Re-resolve all players to check group membership
		self:_resolveAllPlayers()

		-- Persist and sync if dynamic
		if datastore and self._dsGroupAuth then
			task.spawn(function()
				internal.dsUpdate(self._dsGroupAuth, "groups", function(current)
					current = current or {}
					local stored = internal.normalizeGroupEntry(current[tostring(id)]) or {}
					stored[roleName] = minRank
					current[tostring(id)] = stored
					return current
				end)
			end)

			internal.publish(self._msgChannel, {
				action = ACTION.AUTH_GROUP,
				groupId = id,
				roleName = roleName,
				rank = minRank,
			})
		end

		return true
	end

	return false
end

--[[
	Revokes authorization for a user, or every role bound to a group.
	Use deauthGroupRole to remove a single role from a group.
	@param authType Either "user" or "group"
	@param id The user ID or group ID to revoke
	@param datastore (Optional) Persist and broadcast this revocation
	@return true if successful, false otherwise
]]
function marble:deauth(authType: "user" | "group", id: number, datastore: boolean?): boolean
	if not isServer then return false end
	if not internal.validateNumber(id, "id") then return false end

	if authType == "user" then
		self.authorized.Users[id] = nil
		self.userRoles[id] = nil

		-- Resolve for currently connected player
		local player = Players:GetPlayerByUserId(id)
		if player then
			self:_resolvePlayerRoles(player)
		end

		-- Persist and sync if dynamic
		if datastore and self._dsUserAuth then
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
		self.authorized.Groups[id] = nil

		-- Re-resolve all players
		self:_resolveAllPlayers()

		-- Persist and sync if dynamic
		if datastore and self._dsGroupAuth then
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
	Removes a single role binding from a group, leaving its other roles intact.
	@param groupId The group to modify
	@param roleName The role binding to remove
	@param datastore (Optional) Persist and broadcast this revocation
	@return true if the binding existed and was removed, false otherwise
]]
function marble:deauthGroupRole(groupId: number, roleName: string, datastore: boolean?): boolean
	if not isServer then return false end
	if not internal.validateNumber(groupId, "groupId") then return false end
	if not internal.validateString(roleName, "role name") then return false end

	local bindings = self.authorized.Groups[groupId]
	if not bindings or bindings[roleName] == nil then return false end

	bindings[roleName] = nil
	if next(bindings) == nil then
		self.authorized.Groups[groupId] = nil
	end

	self:_resolveAllPlayers()

	if datastore and self._dsGroupAuth then
		task.spawn(function()
			internal.dsUpdate(self._dsGroupAuth, "groups", function(current)
				current = current or {}
				local stored = internal.normalizeGroupEntry(current[tostring(groupId)])
				if stored then
					stored[roleName] = nil
					current[tostring(groupId)] = next(stored) ~= nil and stored or nil
				end
				return current
			end)
		end)

		internal.publish(self._msgChannel, {
			action = ACTION.DEAUTH_GROUP_ROLE,
			groupId = groupId,
			roleName = roleName,
		})
	end

	return true
end

--[[
	Revokes all users and groups authorized with a specific role.
	Useful for removing access when a role is deleted or compromised.
	Also purges persisted assignments and broadcasts to other servers when
	DataStore features are enabled.
	@param roleName The role to deauthorize
	@return The number of entries removed
]]
function marble:deauthRole(roleName: string): number
	if not isServer then return 0 end
	if not internal.validateRole(self, roleName) then return 0 end

	local removed = self:_stripRole(roleName)

	-- Re-resolve all players
	self:_resolveAllPlayers()

	-- Purge persisted assignments regardless of whether the role itself is dynamic,
	-- since users and groups can be saved under a code-defined role
	if self._dsUserAuth then
		task.spawn(function()
			internal.dsUpdate(self._dsUserAuth, "users", function(current)
				current = current or {}
				for userIdStr, storedRole in current do
					if storedRole == roleName then
						current[userIdStr] = nil
					end
				end
				return current
			end)
		end)
	end

	if self._dsGroupAuth then
		task.spawn(function()
			internal.dsUpdate(self._dsGroupAuth, "groups", function(current)
				current = current or {}
				for groupIdStr, entry in current do
					local stored = internal.normalizeGroupEntry(entry)
					if stored and stored[roleName] ~= nil then
						stored[roleName] = nil
						current[groupIdStr] = next(stored) ~= nil and stored or nil
					end
				end
				return current
			end)
		end)
	end

	-- Sync to other servers (no-op when DataStore features are disabled)
	internal.publish(self._msgChannel, {
		action = ACTION.DEAUTH_ROLE,
		roleName = roleName,
	})

	return removed
end

--// Public API - Permission Checking

--[[
	Checks if a user has a specific permission.
	Roles are consulted from highest to lowest priority and the first role that
	explicitly states the permission wins, so a high-priority role can deny a
	permission a lower one grants.
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

	for _, roleName in roles do
		local role = self.roles[roleName]
		local value = role and role.permissions[permission]
		if value ~= nil then
			return value == true
		end
	end

	return false
end

--[[
	Gets all roles assigned to a user, ordered from highest to lowest priority.
	@param userId The user ID
	@return Array of role names, or empty array if user has no roles
]]
function marble:getUserRoles(userId: number): {string}
	if not isServer then return {} end
	if not internal.validateNumber(userId, "userId") then return {} end
	local roles = self.userRoles[userId]
	return roles and table.clone(roles) or {}
end

--[[
	Gets the highest-priority role a user currently holds.
	@param userId The user ID
	@return The role name and its data, or nil if the user has no roles
]]
function marble:getTopRole(userId: number): (string?, Role?)
	if not isServer then return nil, nil end
	if not internal.validateNumber(userId, "userId") then return nil, nil end

	local roles = self.userRoles[userId]
	local topRole = roles and roles[1]
	if not topRole then return nil, nil end
	return topRole, self.roles[topRole]
end

--[[
	Gets all permissions for a user across all their roles.
	Lower-priority roles are applied first so higher-priority roles override them.
	@param userId The user ID
	@return Table mapping permission names to their effective value
]]
function marble:getUserPermissions(userId: number): {[string]: boolean}
	if not isServer then return {} end
	if not internal.validateNumber(userId, "userId") then return {} end

	local permissions = {}
	local roles = self.userRoles[userId]
	if not roles then return permissions end

	-- userRoles is ordered highest first, so walk it backwards
	for index = #roles, 1, -1 do
		local role = self.roles[roles[index]]
		if role then
			for perm, val in role.permissions do
				permissions[perm] = val == true
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
	for userId, role in self.authorized.Users do
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
	for groupId, bindings in self.authorized.Groups do
		local minRank = typeof(bindings) == "table" and bindings[roleName]
		if minRank then
			table.insert(groups, { groupId = groupId, rank = minRank })
		end
	end
	return groups
end

--[[
	Gets every role bound to a group and the rank each one requires.
	@param groupId The group to query
	@return Table mapping role names to their minimum rank
]]
function marble:getGroupRoles(groupId: number): {[string]: number}
	if not isServer then return {} end
	if not internal.validateNumber(groupId, "groupId") then return {} end

	local bindings = self.authorized.Groups[groupId]
	return bindings and table.clone(bindings) or {}
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
	Gets all registered roles ordered from highest to lowest priority.
	@return Array of {name, role} entries
]]
function marble:getRolesByPriority(): {{name: string, role: Role}}
	if not isServer then return {} end

	local ordered = {}
	for roleName, role in self.roles do
		table.insert(ordered, { name = roleName, role = role })
	end
	table.sort(ordered, function(a, b)
		return internal.outranks(self, a.name, 0, b.name, 0)
	end)
	return ordered
end

--[[
	Gets all registered permissions.
	@return Array of permission names
]]
function marble:getAllPermissions(): {string}
	if not isServer then return {} end
	local perms = {}
	for perm in self.permissions do
		table.insert(perms, perm)
	end
	table.sort(perms)
	return perms
end

return marble
