#!/usr/bin/env python3

# Copyright (C) 2020  The Software Heritage developers
# See the AUTHORS file at the top-level directory of this distribution
# License: GNU Affero General Public License version 3, or any later version
# See top-level LICENSE file for more information

from keycloak import KeycloakAdmin


server_url = "http://localhost:8080/keycloak/auth/"
realm_name = "SoftwareHeritage"
client_name = "swh-web"

admin = {"username": "admin", "password": "admin"}


def assign_client_base_url(keycloak_admin, client_name, base_url):
    client_data = {"baseUrl": base_url, "clientId": client_name}
    client_id = keycloak_admin.get_client_id(client_name)
    keycloak_admin.update_client(client_id, client_data)


def assign_client_role_to_user(keycloak_admin, client_name, client_role, username):
    client_id = keycloak_admin.get_client_id(client_name)
    staff_user_role = keycloak_admin.get_client_role(client_id, client_role)
    user_id = keycloak_admin.get_user_id(username)
    keycloak_admin.assign_client_role(user_id, client_id, staff_user_role)


def assign_client_roles_to_user(keycloak_admin, client_name, client_roles, username):
    for client_role in client_roles:
        assign_client_role_to_user(keycloak_admin, client_name, client_role, username)


def create_user(keycloak_admin, user_data):
    try:
        keycloak_admin.create_user(user_data)
    except Exception:
        # user already created
        pass


def create_client_roles(keycloak_admin, client_name, client_roles):
    for client_role in client_roles:
        keycloak_admin.create_client_role(client_name, payload={"name": client_role})


# login as admin in master realm
keycloak_admin = KeycloakAdmin(server_url, admin["username"], admin["password"])

# update master realm clients base urls as we use a reverse proxy
assign_client_base_url(
    keycloak_admin, "account", "/keycloak/auth/realms/master/account"
)

assign_client_base_url(
    keycloak_admin,
    "security-admin-console",
    "/keycloak/auth/admin/master/console/index.html",
)

keycloak_admin.update_realm(
    "master", payload={"loginTheme": "swh", "accountTheme": "swh", "adminTheme": "swh",}
)

# create swh realm
keycloak_admin.create_realm(
    payload={
        "realm": realm_name,
        "rememberMe": True,
        "attributes": {"frontendUrl": "http://localhost:5080/keycloak/auth/"},
        "enabled": True,
        "loginTheme": "swh",
        "accountTheme": "swh",
        "adminTheme": "swh",
    },
    skip_exists=True,
)

# set swh realm name in order to create users in it
keycloak_admin.realm_name = realm_name

# update swh realm clients base urls as we use a reverse proxy
assign_client_base_url(
    keycloak_admin, "account", f"/keycloak/auth/realms/{realm_name}/account"
)

assign_client_base_url(
    keycloak_admin,
    "security-admin-console",
    f"/keycloak/auth/admin/{realm_name}/console/index.html",
)

# create an admin user in the swh realm
user_data = {
    "email": "admin@example.org",
    "username": admin["username"],
    "firstName": admin["username"],
    "lastName": admin["username"],
    "credentials": [
        {"value": admin["username"], "type": admin["password"], "temporary": False}
    ],
    "enabled": True,
    "emailVerified": False,
}

create_user(keycloak_admin, user_data)

# assign realm admin roles to created user
realm_management_roles = [
    "view-users",
    "view-events",
    "view-identity-providers",
    "manage-identity-providers",
    "create-client",
    "query-clients",
    "query-realms",
    "manage-events",
    "view-clients",
    "manage-realm",
    "impersonation",
    "manage-clients",
    "view-authorization",
    "query-users",
    "view-realm",
    "manage-authorization",
    "manage-users",
    "query-groups",
]
assign_client_roles_to_user(
    keycloak_admin, "realm-management", realm_management_roles, admin["username"]
)


# login as admin in swh realm
keycloak_admin = KeycloakAdmin(
    server_url, admin["username"], admin["password"], realm_name
)

# create swh-web public client
keycloak_admin.create_client(
    payload={
        "id": client_name,
        "clientId": client_name,
        "surrogateAuthRequired": False,
        "enabled": True,
        "redirectUris": ["http://localhost:5004/*",],
        "bearerOnly": False,
        "consentRequired": False,
        "standardFlowEnabled": True,
        "implicitFlowEnabled": False,
        "directAccessGrantsEnabled": True,
        "serviceAccountsEnabled": False,
        "publicClient": True,
        "frontchannelLogout": False,
        "protocol": "openid-connect",
        "fullScopeAllowed": True,
        "protocolMappers": [
            {
                "name": "user groups",
                "protocol": "openid-connect",
                "protocolMapper": "oidc-group-membership-mapper",
                "consentRequired": False,
                "config": {
                    "full.path": True,
                    "userinfo.token.claim": True,
                    "id.token.claim": True,
                    "access.token.claim": True,
                    "claim.name": "groups",
                    "jsonType.label": "String",
                },
            },
            {
                "name": "audience",
                "protocol": "openid-connect",
                "protocolMapper": "oidc-audience-mapper",
                "consentRequired": False,
                "config": {
                    "included.client.audience": client_name,
                    "id.token.claim": True,
                    "access.token.claim": True,
                },
            },
        ],
    },
    skip_exists=True,
)

# create staff group
keycloak_admin.create_group(payload={"name": "staff",}, skip_exists=True)

groups = keycloak_admin.get_groups()

admin_user_id = keycloak_admin.get_user_id(username=admin["username"])

for group in groups:
    if group["name"] == "staff":
        keycloak_admin.group_user_add(admin_user_id, group["id"])
        break

# create swh-web client roles
create_client_roles(
    keycloak_admin,
    client_name,
    ["swh.web.api.throttling_exempted", "swh.web.api.graph"],
)

# create some test users
user_data = {
    "email": "john.doe@example.org",
    "username": "johndoe",
    "firstName": "John",
    "lastName": "Doe",
    "credentials": [{"value": "johndoe-swh", "type": "password", "temporary": False}],
    "enabled": True,
    "emailVerified": False,
}
create_user(keycloak_admin, user_data)

user_data = {
    "email": "jane.doe@example.org",
    "username": "janedoe",
    "firstName": "Jane",
    "lastName": "Doe",
    "credentials": [{"value": "janedoe-swh", "type": "password", "temporary": False}],
    "enabled": True,
    "emailVerified": False,
}
create_user(keycloak_admin, user_data)
