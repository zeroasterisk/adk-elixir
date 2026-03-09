#!/usr/bin/env python3
"""Get a GCP OAuth2 bearer token from a service account JSON key file.

Usage:
    GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json python3 test/integration/get_bearer_token.py

Prints the access token to stdout (no newline).
"""
import json, time, base64, subprocess, tempfile, os, sys
from urllib.request import urlopen, Request
from urllib.parse import urlencode

key_file = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
if not key_file:
    print("GOOGLE_APPLICATION_CREDENTIALS not set", file=sys.stderr)
    sys.exit(1)

with open(key_file) as f:
    sa = json.load(f)

header = base64.urlsafe_b64encode(json.dumps({"alg": "RS256", "typ": "JWT"}).encode()).rstrip(b'=').decode()
now = int(time.time())
claims = {
    "iss": sa["client_email"],
    "scope": "https://www.googleapis.com/auth/generative-language https://www.googleapis.com/auth/cloud-platform",
    "aud": "https://oauth2.googleapis.com/token",
    "iat": now,
    "exp": now + 3600,
}
payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).rstrip(b'=').decode()
signing_input = f"{header}.{payload}"

with tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False) as kf:
    kf.write(sa["private_key"])
    tmp_key = kf.name

try:
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", tmp_key],
        input=signing_input.encode(), capture_output=True, check=True,
    )
finally:
    os.unlink(tmp_key)

signature = base64.urlsafe_b64encode(result.stdout).rstrip(b'=').decode()
jwt = f"{signing_input}.{signature}"

data = urlencode({"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": jwt}).encode()
req = Request("https://oauth2.googleapis.com/token", data=data, method="POST")
resp = json.loads(urlopen(req).read())
print(resp["access_token"], end="")
