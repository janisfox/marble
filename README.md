# Marble
**Marble is a Role-Based Access Control (RBAC) permission module for Roblox.**
## Features
It provides:
- Roles
- Permissions
- Role priority (highest role wins)
- Multi-role groups
- DataStore-backed persistence
- Easy-to-use API

Perfect for:
- Admin systems
- Game permissions
- Secure feature access

## How to use
Example:
```luau
local marble = require(path)

local runtime = marble.new("adminSystem", {datastore = "admin", scope = "system"}
runtime:waitUntilReady()

marble:registerPermission({"use_panel", "ban"})
-- or..
marble:registerPermission("kick")

marble:registerRole({
  name = "Owner",
  permissions = {
    use_panel = true,
    ban = true,
    kick = true,
  }
  color = Color3.new(1, 0, 0), -- color system if you want
  priority = 100, -- cosmetic like color, but also decides which role wins
})

marble:auth("user", 123, "Owner")

-- A group can grant several roles, each behind its own minimum rank.
-- A player gets the highest-priority role they qualify for.
marble:auth("group", 456, "Owner", 255)
marble:auth("group", 456, "Moderator", 100)
```

---
### marble.new
Creates a new runtime.
```luau
-- @param key A unique identifier for this runtime
-- @param data Configuration options (datastore name, scope)
-- @return The new Marble runtime instance
marble.new(key: string, {datastore: string, scope: string})
```
### marble.getRuntime
Retrieves a runtime instance by key (server only).
```luau
-- @param key The runtime key
-- @return The runtime instance, or nil if not found
marble.getRuntime(key: string)
```
---
### marble.waitUntilReady
Waits until the Datastore of the Authentication table finished loading.
```luau
marble.waitUntilReady(self)
runtime:waitUntilReady()
```
### marble.registerPermission
Registers one or more permissions in the system.
Permissions must be registered before they can be used in roles.
```luau
-- @param perms A string or array of permission names to register
marble.registerPermission(self, perms: string | {string})
runtime:registerPermission(perms: string | {string})
```
### marble.registerRole
Registers a new role in the system.
Roles can have multiple permissions and optional metadata (color, priority, management flags).
Priority is descriptive data like color, but it also decides which role wins when several
apply to the same player. Higher priority wins; it defaults to 0.
```luau
-- @param data The role data (name, permissions, optional color/priority/flags)
-- @return true if successful, false otherwise
export type RoleData = {
  name: string,
  permissions: {[string]: boolean},
  color: Color3?,
  priority: number?,
  datastore: boolean?,
}
marble.registerRole(self, data: RoleData)
runtime:registerRole(data: RoleData)
```
### marble.modifyRole
Modifies an existing role.
Takes either a plain permissions map, or a changes table to also update color and priority.
Can only modify permissions that are already registered.
Re-resolves all connected players after modification.
```luau
-- @param roleName The role to modify
-- @param changes Permission updates, or a table of role changes
-- @return true if successful, false otherwise
export type RoleChanges = {
  permissions: {[string]: boolean}?,
  color: Color3?,
  priority: number?,
}
marble.modifyRole(self, roleName: string, changes: {[string]: boolean} | RoleChanges)
runtime:modifyRole(roleName: string, changes: {[string]: boolean} | RoleChanges)

-- both forms work
runtime:modifyRole("Moderator", {ban = false})
runtime:modifyRole("Moderator", {permissions = {ban = false}, priority = 50})
```
### marble.auth
Authorizes a user or group to receive a specific role.
Validates that the role exists and the ID is valid.
Group authorizations are additive: a group can bind several roles, each with its own
minimum rank, and a player receives the highest-priority role they qualify for.
Re-authorizing the same role on a group updates its rank.
```luau
-- @param authType Either "user" or "group"
-- @param id The user ID or group ID
-- @param roleName The role to grant
-- @param rank (Optional) Minimum group rank required (for group auth)
-- @return true if successful, false otherwise
marble.auth(self, authType: "user" | "group", id: number, roleName: string, rank: number?, datastore: boolean?)
runtime:auth(authType: "user" | "group", id: number, roleName: string, rank: number?, datastore: boolean?)
```
### marble.deauth
Revokes authorization for a user, or every role bound to a group.
Use `deauthGroupRole` to remove a single role from a group.
```luau
-- @param authType Either "user" or "group"
-- @param id The user ID or group ID to revoke
-- @return true if successful, false otherwise
marble.deauth(self, authType: "user" | "group", id: number, datastore: boolean?)
runtime:deauth(authType: "user" | "group", id: number, datastore: boolean?)
```
### marble.deauthGroupRole
Removes a single role binding from a group, leaving its other roles intact.
```luau
-- @param groupId The group to modify
-- @param roleName The role binding to remove
-- @return true if the binding existed and was removed, false otherwise
marble.deauthGroupRole(self, groupId: number, roleName: string, datastore: boolean?)
runtime:deauthGroupRole(groupId: number, roleName: string, datastore: boolean?)
```
---
### marble.deauthRole
Revokes all users and groups authorized with a specific role.
Useful for removing access when a role is deleted or compromised.
```luau
-- @param data The role name
-- @return true if successful, false otherwise
marble.deauthRole(self, role: string)
runtime:deauthRole(role: string)
```
### marble.hasPermission
Checks if a user has a specific permission.
Roles are consulted from highest to lowest priority and the first role that explicitly
states the permission wins, so a high-priority role can deny what a lower one grants.
```luau
-- @param userId The user ID to check
-- @param permission The permission name
-- @return true if the user has the permission, false otherwise
marble.hasPermission(self, userId: number, permission: string)
runtime:hasPermission(userId: number, permission: string)
```
---
### marble.getAuthorizedUsers
Gets all users authorized with a specific role.
```luau
-- @param roleName The role to query
-- @return Array of user IDs with that role
marble.getAuthorizedUsers(self, roleName: string)
runtime:getAuthorizedUsers(roleName: string)
```
### marble.getAuthorizedGroups
Gets all groups authorized with a specific role.
```luau
-- @param roleName The role to query
-- @return Array of {groupId, rank} pairs
marble.getAuthorizedGroups(self, roleName: string)
runtime:getAuthorizedGroups(roleName: string)
```
### marble.getGroupRoles
Gets every role bound to a group and the rank each one requires.
```luau
-- @param groupId The group to query
-- @return Table mapping role names to their minimum rank
marble.getGroupRoles(self, groupId: number)
runtime:getGroupRoles(groupId: number)
```
### marble.getTopRole
Gets the highest-priority role a user currently holds.
```luau
-- @param userId The user ID
-- @return The role name and its data, or nil if the user has no roles
marble.getTopRole(self, userId: number)
runtime:getTopRole(userId: number)
```
### marble.getRole
Gets a specific role's data.
```luau
-- @param roleName The role name
-- @return The role data, or nil if not found
marble.getRole(self, roleName: string)
runtime:getRole(roleName: string)
```
### marble.getAllRoles
Gets all registered roles.
```luau
-- @return Table mapping role names to role data
marble.getAllRoles(self)
runtime:getAllRoles()
```
### marble.getRolesByPriority
Gets all registered roles ordered from highest to lowest priority.
```luau
-- @return Array of {name, role} entries
marble.getRolesByPriority(self)
runtime:getRolesByPriority()
```
### marble.getAllPermissions
Gets all registered permissions.
```luau
-- @return Array of permission names
marble.getAllPermissions(self)
runtime:getAllPermissions()
```
---
### marble.destroy
Tears down a runtime: disconnects handlers, releases signals and unregisters it from the
runtime table. The instance must not be used afterwards.
```luau
marble.destroy(self)
runtime:destroy()
```
