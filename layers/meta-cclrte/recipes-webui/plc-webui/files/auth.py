"""
CCLRTE WebUI Authentication
Simple file-based credential store with bcrypt hashing.
"""

import os
import json
import hashlib
import hmac
from functools import wraps
from flask import session, redirect, url_for

CREDS_FILE = '/var/lib/cclrte/webui-credentials.json'
DEFAULT_USER = 'admin'
DEFAULT_PASS = 'admin'  # Changed on first login via WebUI System page

def _hash_password(password: str) -> str:
    salt = os.urandom(32).hex()
    dk = hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), 200000)
    return f"{salt}:{dk.hex()}"

def _verify_password(password: str, stored: str) -> bool:
    try:
        salt, dk_hex = stored.split(':', 1)
        dk = hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), 200000)
        return hmac.compare_digest(dk.hex(), dk_hex)
    except Exception:
        return False

def _load_creds() -> dict:
    try:
        with open(CREDS_FILE) as f:
            return json.load(f)
    except Exception:
        return {DEFAULT_USER: _hash_password(DEFAULT_PASS)}

def _save_creds(creds: dict):
    os.makedirs(os.path.dirname(CREDS_FILE), exist_ok=True)
    with open(CREDS_FILE, 'w') as f:
        json.dump(creds, f)
    os.chmod(CREDS_FILE, 0o600)

def check_credentials(username: str, password: str) -> bool:
    creds = _load_creds()
    if username not in creds:
        return False
    return _verify_password(password, creds[username])

def set_password(username: str, new_password: str):
    creds = _load_creds()
    creds[username] = _hash_password(new_password)
    _save_creds(creds)

def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if 'user' not in session:
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated
