# Marble
**Marble is a Role-Based Access Control (RBAC) system for Roblox.**
## Features
It provides:
- Roles
- Permissions
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
})

marble:auth("user", 123, "Owner")
marble:auth("group", 456, "Owner", 255)
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
Roles can have multiple permissions and optional metadata (color, management flags).
```luau
-- @param data The role data (name, permissions, optional color/flags)
-- @return true if successful, false otherwise
export type RoleData = {
  name: string,
  permissions: {[string]: boolean},
  color: Color3?,
  datastore: boolean?,
}
marble.registerRole(self, data: RoleData)
runtime:registerRole(data: RoleData)
```
### marble.modifyRole
Modifies permissions of an existing role.
Can only modify permissions that are already registered.
Re-resolves all connected players after modification.
```luau
-- @param roleName The role to modify
-- @param newPermissions Table of permission updates
-- @return true if successful, false otherwise
marble.modifyRole(self, roleName: string, newPermissions: {[string]: boolean})
runtime:modifyRole(roleName: string, newPermissions: {[string]: boolean})
```
### marble.auth
Authorizes a user or group to receive a specific role.
Validates that the role exists and the ID is valid.
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
Revokes authorization for a user or group.
```luau
@param authType Either "user" or "group"
@param id The user ID or group ID to revoke
@return true if successful, false otherwise
marble.deauth(self, authType: "user" | "group", id: number, datastore: boolean?)
runtime:deauth(authType: "user" | "group", id: number, datastore: boolean?)
```
---
### marble.dauthRole
Revokes all users and groups authorized with a specific role.
Useful for removing access when a role is deleted or compromised.
```luau
-- @param roleName The role to deauthorize
-- @return The number of entries removed
marble.waitUntilReady(self, roleName: string)
runtime:waitUntilReady(roleName: string)
```
### marble.hasPermission
Checks if a user has a specific permission.
Looks through all roles assigned to the user.
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
### marble.getAllPermissions
Gets all registered permissions.
```luau
-- @return Array of permission names
marble.getAllPermissions(self)
runtime:getAllPermissions()
```
