import requests
import os
import subprocess
import argparse
import sys
import re
from urllib.parse import urlparse

# Disable SSL warnings
requests.packages.urllib3.disable_warnings()

# Configuration constants
RSA_KEY_SIZE = 2048
CERT_VALIDITY_DAYS = 365

def parse_args():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(description='Fortanix KMIP Application Setup')
    parser.add_argument('--email', required=True, help='Email for Fortanix login')
    parser.add_argument('--password', required=True, help='Password for Fortanix login')
    parser.add_argument('--dsm-url', default='https://eu.smartkey.io', help='Fortanix DSM URL')
    parser.add_argument('--api-url', default='https://api.eu.smartkey.io', help='Fortanix API URL')
    parser.add_argument('--app-name', default='TestingMySQL', help='Application name')
    parser.add_argument('--group-name', default='TestingMySQL', help='Group name')
    parser.add_argument('--cert-dir', default='./cert_dir', help='Certificate directory')
    parser.add_argument('-v', '--verbose', action='store_true', help='Verbose output')
    return parser.parse_args()


def api_request(method, endpoint, token=None, payload=None, cert=None, base_url=None, verbose=False):
    """Make API request with error handling"""
    url = f"{base_url}{endpoint}" if endpoint.startswith('/') else f"{base_url}/{endpoint}"
    headers = {"Content-Type": "application/json"}

    if token:
        headers["Authorization"] = f"Bearer {token}"

    if verbose:
        print(f"{method} {url}")

    try:
        response = requests.request(method, url, headers=headers, json=payload, cert=cert, verify=False)
        response.raise_for_status()
        return response.json() if response.content else {}
    except requests.exceptions.RequestException as e:
        error_msg = f"API request failed: {e}"
        if hasattr(e, 'response') and e.response is not None:
            error_msg += f" (Status: {e.response.status_code}, Body: {e.response.text})"
        raise Exception(error_msg)


def authenticate(args):
    """Authenticate and select account"""
    if args.verbose:
        print("\n1. Authenticating...")

    # Login
    auth = api_request('POST', '/sys/v1/session/auth',
                       payload={"method": "password", "email": args.email, "password": args.password},
                       base_url=args.dsm_url, verbose=args.verbose)
    if not auth:
        raise Exception("Authentication failed: Empty response from server")
    token = auth.get('access_token')
    if not token:
        raise Exception("Authentication failed: No access token in response")
    print(f"Authenticated")

    # Get and select account
    accounts = api_request('GET', '/sys/v1/accounts', token=token,
                           base_url=args.dsm_url, verbose=args.verbose)
    if not accounts:
        raise Exception("No accounts found for this user")
    account_id = accounts[0]['acct_id']

    api_request('POST', '/sys/v1/session/select_account',
                token=token, payload={"acct_id": account_id},
                base_url=args.dsm_url, verbose=args.verbose)
    print(f"Account: {account_id}")

    return token, account_id


def get_or_create_group(token, args):
    """Get group ID by name, create if not exists"""
    groups = api_request('GET', '/sys/v1/groups', token=token,
                         base_url=args.dsm_url, verbose=args.verbose)
    group = next((g for g in groups if g.get('name') == args.group_name), None)

    if group:
        print(f"Group found: {group['group_id']}")
        return group['group_id']

    # Create group if not found
    if args.verbose:
        print(f"Group '{args.group_name}' not found, creating...")

    new_group = api_request('POST', '/sys/v1/groups', token=token,
                            payload={"name": args.group_name, "description": f"Auto-created group for {args.app_name}"},
                            base_url=args.dsm_url, verbose=args.verbose)

    print(f"Group created: {new_group['group_id']}")
    return new_group['group_id']


def setup_app(token, group_id, args):
    """Create or recreate application"""
    if args.verbose:
        print("\n2. Setting up application...")

    # Delete existing app if present
    apps = api_request('GET', '/sys/v1/apps', token=token,
                       base_url=args.dsm_url, verbose=args.verbose)
    existing = next((a for a in apps if a.get('name') == args.app_name), None)

    if existing:
        api_request('DELETE', f"/sys/v1/apps/{existing['app_id']}", token=token,
                    base_url=args.dsm_url, verbose=args.verbose)
        print(f"Deleted existing app")

    # Create new app
    app = api_request('POST', '/sys/v1/apps', token=token,
                      payload={
                          "name": args.app_name,
                          "auth_type": "Secret",
                          "description": "Application for Percona MySQL encryption",
                          "add_groups": [group_id],
                          "default_group": group_id
                      },
                      base_url=args.dsm_url, verbose=args.verbose)

    print(f"Created app: {app['app_id']}")
    return app['app_id']


def generate_certs(app_id, args):
    """Generate client certificates"""
    if args.verbose:
        print("\n3. Generating certificates...")

    # Setup directory
    os.makedirs(args.cert_dir, exist_ok=True)

    # Clean existing certificate files only
    key_path = os.path.join(args.cert_dir, "private.key")
    cert_path = os.path.join(args.cert_dir, "certificate.crt")
    for cert_file in [key_path, cert_path]:
        if os.path.isfile(cert_file):
            os.remove(cert_file)

    # Generate certificate
    cmd = [
        "openssl", "req", "-newkey", f"rsa:{RSA_KEY_SIZE}", "-nodes",
        "-keyout", key_path, "-x509", "-days", str(CERT_VALIDITY_DAYS),
        "-out", cert_path, "-subj", f"/CN={app_id}"
    ]

    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError as e:
        raise Exception(f"Certificate generation failed: {e.stderr}")
    except FileNotFoundError:
        raise Exception("OpenSSL not found. Please install OpenSSL.")

    print(f"Certificates generated")
    return cert_path, key_path


def enable_cert_auth(token, app_id, cert_path, args):
    """Enable certificate authentication"""
    if args.verbose:
        print("\n4. Enabling certificate auth...")

    with open(cert_path, 'r') as f:
        cert_content = f.read()

    # Clean certificate (remove headers and whitespace)
    cert_body = re.sub(r'-----.*?-----|\s', '', cert_content)

    api_request('PATCH', f'/sys/v1/apps/{app_id}', token=token,
                payload={"auth_type": "Certificate", "credential": {"certificate": cert_body}},
                base_url=args.dsm_url, verbose=args.verbose)

    print("Certificate auth enabled")


def test_cert_auth(cert_path, key_path, args):
    """Test certificate authentication"""
    if args.verbose:
        print("\n5. Testing certificate auth...")

    auth = api_request('POST', '/sys/v1/session/auth',
                       cert=(cert_path, key_path),
                       base_url=args.api_url, verbose=args.verbose)

    token = auth.get('access_token')
    if not token:
        raise Exception("No access token received")

    print(f"Certificate auth successful!")
    return token


def download_server_cert(args):
    """Download server certificate"""
    if args.verbose:
        print("\n6. Downloading server certificate...")

    # Extract hostname from DSM URL
    hostname = urlparse(args.dsm_url).netloc

    cmd = ["openssl", "s_client", "-connect", f"{hostname}:443", "-servername", hostname]

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True,
            input="", timeout=10
        )

        # Extract certificate
        match = re.search(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
                          result.stdout, re.DOTALL)

        if match:
            server_cert_path = os.path.join(args.cert_dir, "server.crt")
            with open(server_cert_path, 'w') as f:
                f.write(match.group(0))
            print(f"Server certificate saved")
        else:
            print("Could not extract server certificate")

    except subprocess.TimeoutExpired:
        raise Exception("Server certificate download timed out")
    except Exception as e:
        raise Exception(f"Server certificate download failed: {e}")


def main():
    """Main execution"""
    args = parse_args()

    print("Fortanix KMIP Setup")

    try:
        # Step 1: Authenticate
        token, account_id = authenticate(args)

        # Get group
        group_id = get_or_create_group(token, args)

        # Step 2: Setup application
        app_id = setup_app(token, group_id, args)

        # Step 3: Generate certificates
        cert_path, key_path = generate_certs(app_id, args)

        # Step 4: Enable certificate auth
        enable_cert_auth(token, app_id, cert_path, args)

        # Step 5: Test certificate auth
        test_cert_auth(cert_path, key_path, args)

        # Step 6: Download server cert
        download_server_cert(args)

        print("\nSetup completed successfully!")
        print(f"Certificates: {args.cert_dir}")

    except Exception as e:
        print(f"\nError: {e}")
        if args.verbose:
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
