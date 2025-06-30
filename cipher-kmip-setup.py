import requests
import os
import random
import string
import argparse
from urllib.parse import quote
from urllib3.exceptions import InsecureRequestWarning

# Disable SSL warnings for self-signed certificates
requests.packages.urllib3.disable_warnings(InsecureRequestWarning)

def generate_secure_password(length=12):
    """Generate a secure password with at least one of each character type"""
    special_chars = "!@#$%^&*()-_=+"
    password_chars = (
        random.choice(string.ascii_uppercase) +
        random.choice(string.ascii_lowercase) +
        random.choice(string.digits) +
        random.choice(special_chars) +
        ''.join(random.choices(string.ascii_letters + string.digits + special_chars, k=length - 4))
    )
    password_list = list(password_chars)
    random.shuffle(password_list)
    return ''.join(password_list)

# Parse command line arguments
parser = argparse.ArgumentParser(description='KMIP Client Setup for CipherTrust Manager')
parser.add_argument('--admin-pass', required=True, help='Password for admin user')
parser.add_argument('--ip', required=True, help='CTM IP address')
parser.add_argument('--username', default='testmysql', help='Username to create (default: testmysql)')
parser.add_argument('--client-name', default='mysql-client', help='KMIP client name (default: mysql-client)')
parser.add_argument('--cert-dir', default='./ciper-kmip', help='Certificate store directory (default: ./certs)')
parser.add_argument('-v', '--verbose', action='store_true', help='Enable verbose output')
args = parser.parse_args()

# Configuration
CTM_IP = args.ip
ADMIN_PASS = args.admin_pass
USERNAME = args.username
USER_PASS = generate_secure_password(12)  # Generate secure password
CLIENT_NAME = args.client_name

# Base URL
base_url = f"https://{CTM_IP}/api/v1"

def make_request(method, endpoint, headers=None, data=None):
    """Helper function to make HTTP requests"""
    url = f"{base_url}{endpoint}"
    response = requests.request(
        method=method,
        url=url,
        headers=headers,
        json=data,
        verify=False  # Skip SSL verification (equivalent to -k flag)
    )
    return response

# Get authentication token
print("Getting authentication token...")
auth_data = {
    "name": "admin",
    "password": ADMIN_PASS,
    "validity_period": 86400
}

auth_response = make_request("POST", "/auth/tokens/", data=auth_data)
if auth_response.status_code != 200:
    raise Exception(f"Authentication failed. Status: {auth_response.status_code}")

jwt_token = auth_response.json()["jwt"]
print("Authentication successful")

# Set up headers with JWT token
headers = {
    "Authorization": f"Bearer {jwt_token}",
    "Content-Type": "application/json"
}

# Get license information
license_response = make_request("GET", "/licensing/trials/", headers=headers)
license_data = license_response.json()['resources'][0]

license_data = license_response.json()['resources'][0]
license_status = license_data['status']
license_id = license_data['id']

# Activate only if new instance or deactivated state
if license_status in ["deactivated", "available"]:
    activate_response = make_request("POST", f"/licensing/trials/{license_id}/activate", headers=headers)
    activate_response.raise_for_status()

# Create user
print(f"Creating user: {USERNAME}")
user_data = {
    "username": USERNAME,
    "password": USER_PASS,
    "email": f"{USERNAME}@example.com"
}

user_response = make_request("POST", "/usermgmt/users/", headers=headers, data=user_data)

if user_response.status_code == 201 or user_response.status_code == 200:
    user_response_json = user_response.json()
    user_id = user_response_json["user_id"]
    print("User created successfully")
elif user_response.status_code == 409:  # Conflict - user already exists
    print("User already exists, fetching user ID...")
    # Get user list to find the user ID
    users_response = make_request("GET", "/usermgmt/users/", headers=headers)
    users_list = users_response.json()
    for user in users_list.get("resources", []):
        if user.get("username") == USERNAME:
            user_id = user.get("user_id")
            print("Found existing user")
            break
    else:
        raise Exception(f"Could not find user ID for {USERNAME}")
else:
    raise Exception(f"Failed to create user. Status: {user_response.status_code}")

# Assign to Key Admins group
print("Assigning user to Key Admins group...")
# URL encode the user_id since it contains special characters like '|'
encoded_user_id = quote(user_id, safe='')
group_response = make_request("POST", f"/usermgmt/groups/Key%20Admins/users/{encoded_user_id}", headers=headers)

if group_response.status_code not in [200, 201, 204]:
    print(f"Warning: Failed to add user to Key Admins group. Status: {group_response.status_code}")
else:
    print("Successfully added user to Key Admins group")

# Create profile for KMIP
print("Creating KMIP profile...")
profile_data = {
    "name": "mysql",
    "subject_dn_field_to_modify": "UID",
    "properties": {
        "cert_user_field": "CN"
    },
    "device_credential": {}
}

profile_response = make_request("POST", "/kmip/kmip-profiles", headers=headers, data=profile_data)

# Register the token for KMIP
print("Registering KMIP token...")
token_data = {
    "name_prefix": "mysql",
    "profile_name": "mysql",
    "max_clients": 100
}

token_response = make_request("POST", "/kmip/regtokens/", headers=headers, data=token_data)
if token_response.status_code not in [200, 201]:
    raise Exception(f"Token registration failed. Status: {token_response.status_code}")

kmip_token = token_response.json()["token"]
print("KMIP token registered successfully")

# Adjust Interface for MySQL Auth/Cert mode
print("Adjusting KMIP interface mode...")
interface_data = {"mode": "tls-pw-opt"}
interface_response = make_request("PATCH", "/configs/interfaces/kmip", headers=headers, data=interface_data)

# Create the KMIP Client setup using the token
print(f"Creating KMIP client: {CLIENT_NAME}")
client_data = {
    "name": CLIENT_NAME,
    "reg_token": kmip_token
}

client_response = make_request("POST", "/kmip/kmip-clients", headers=headers, data=client_data)

if client_response.status_code in [200, 201]:
    client_resp_json = client_response.json()
    print("KMIP client created successfully")
elif client_response.status_code == 409:  # Conflict - client already exists
    raise Exception(f"KMIP client '{CLIENT_NAME}' already exists. Please change the CLIENT_NAME variable in the script and try again.")
else:
    raise Exception(f"KMIP client creation failed. Status: {client_response.status_code}")

# Save certificate files
print("Saving certificate files...")

# Create the certificate directory if it doesn't exist
os.makedirs(args.cert_dir, exist_ok=True)

# Save private key to client_key.pem
key_file_path = os.path.join(args.cert_dir, "client_key.pem")
with open(key_file_path, "w") as key_file:
    key_file.write(client_resp_json["key"])

# Save certificate to client_certificate.pem
cert_file_path = os.path.join(args.cert_dir, "client_certificate.pem")
with open(cert_file_path, "w") as cert_file:
    cert_file.write(client_resp_json["cert"])

# Save CA certificate to root_certificate.pem
ca_file_path = os.path.join(args.cert_dir, "root_certificate.pem")
with open(ca_file_path, "w") as ca_file:
    ca_file.write(client_resp_json["client_ca"])

# Set restrictive permissions on private key file (equivalent to chmod 600)
os.chmod(key_file_path, 0o600)

if args.verbose:
    print("KMIP setup completed successfully!")
    print(f"Files created within {args.cert_dir}:")
    print(f"  - Private key: {key_file_path} ")
    print(f"  - Certificate: {cert_file_path}")
    print(f"  - CA certificate: {ca_file_path}")
