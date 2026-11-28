"""Exercise the production Compose service pins through the fixture nginx listener."""
import argparse
import base64
import hashlib
import http.client
import json
import secrets
import sys
import time
from datetime import datetime, timedelta, timezone
from urllib.parse import quote, urlparse

USERNAME = "deploy-smoke"
PASSWORD = "LocalSmoke!123"
SHARE_PASSWORD = "LocalSmokeShare!123"
SHARE_HOST = "share.smoke.invalid"
# A valid one-page PDF and a one-pixel PNG, kept small for repeatable byte checks.
PDF = base64.b64decode(
    "JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2Jq"
    "CjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2Jq"
    "CjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA1MCA1"
    "MF0gPj4KZW5kb2JqCnhyZWYKMCA0CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAwOSAwMDAw"
    "MCBuIAowMDAwMDAwMDU4IDAwMDAwIG4gCjAwMDAwMDAxMTUgMDAwMDAgbiAKdHJhaWxlcgo8PCAv"
    "U2l6ZSA0IC9Sb290IDEgMCBSID4+CnN0YXJ0eHJlZgoxODQKJSVFT0YK"
)
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQKdrxHwAEGgI+wc9OiAAAAABJRU5ErkJggg=="
)
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


class Smoke:
    def __init__(self, port):
        self.port = port
        self.auth = {}

    def request(self, label, path, expected=200, method="GET", body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            check(
                response.status == expected,
                f"{label}: expected HTTP {expected}, got {response.status}",
            )
            return response.read(), response.headers
        finally:
            connection.close()

    def json(self, label, path, body=None):
        if body is None:
            response, _ = self.request(label, path, headers=self.auth)
        else:
            response, _ = self.request(
                label,
                path,
                method="POST",
                body=json.dumps(body),
                headers={**self.auth, "Content-Type": "application/json"},
            )
        try:
            return json.loads(response)
        except ValueError:
            raise RuntimeError(f"{label}: expected a JSON response") from None

    def multipart(self, label, path, filename, contents, mime, fields=()):
        boundary = secrets.token_hex(16)
        parts = []
        for key, value in fields:
            parts.append(
                f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode()
            )
        parts.extend(
            (
                f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\n'
                f"Content-Type: {mime}\r\n\r\n".encode(),
                contents,
                f"\r\n--{boundary}--\r\n".encode(),
            )
        )
        response, _ = self.request(
            label,
            path,
            method="POST",
            body=b"".join(parts),
            headers={**self.auth, "Content-Type": f"multipart/form-data; boundary={boundary}"},
        )
        return response

    def ready(self):
        for attempt in range(60):
            try:
                html, _ = self.request("Load frontend", "/")
                check(b"Vault-Web" in html, "Frontend did not serve the Vault Web SPA")
                docs, _ = self.request("Load server documentation", "/docs/README.md")
                check(
                    docs.startswith(b"# Server Documentation Index"),
                    "Did not serve the documentation index",
                )
                self.json("Probe Vault Web", f"/api/auth/check-username?username={USERNAME}")
                self.request(
                    "Probe Cloud Page through nginx",
                    "/cloud-api/public/secure-sends/smoke-readiness/meta",
                    expected=404,
                    headers={"Host": SHARE_HOST},
                )
                return
            except (OSError, http.client.HTTPException, RuntimeError):
                if attempt == 59:
                    raise
                time.sleep(2)

    def login(self):
        response = self.json("Login", "/api/auth/login", {"username": USERNAME, "password": PASSWORD})
        token = response.get("token")
        check(isinstance(token, str) and token, "Login did not return an access token")
        self.auth = {"Authorization": f"Bearer {token}"}

    def websocket(self):
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        expected = base64.b64encode(hashlib.sha1((key + WEBSOCKET_GUID).encode()).digest()).decode()
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            connection.request(
                "GET",
                "/ws-chat/websocket",
                headers={
                    "Connection": "Upgrade",
                    "Upgrade": "websocket",
                    "Sec-WebSocket-Key": key,
                    "Sec-WebSocket-Version": "13",
                    "Origin": f"http://127.0.0.1:{self.port}",
                },
            )
            response = connection.getresponse()
            check(
                response.status == 101,
                f"WebSocket handshake: expected HTTP 101, got {response.status}",
            )
            check(
                response.headers.get("Sec-WebSocket-Accept") == expected,
                "WebSocket handshake was invalid",
            )
        finally:
            connection.close()

    def read_files(self):
        data, _ = self.request(
            "Download Cloud PDF", "/cloud-api/files/download?path=smoke.pdf", headers=self.auth
        )
        check(data == PDF, "Cloud download differs from the uploaded file")
        response = self.json("Read profile picture metadata", "/api/auth/profile-picture")
        path = response.get("profilePicture")
        check(
            isinstance(path, str) and path.lstrip("/").startswith("uploads/profile-pictures/"),
            "The profile picture URL must point to the nginx uploads route",
        )
        data, _ = self.request("Download profile picture through nginx", "/" + path.lstrip("/"))
        check(data == PNG, "Profile picture differs from the uploaded image")

    def share(self):
        expires_at = datetime.now(timezone.utc) + timedelta(hours=1)
        response = self.json(
            "Create protected Secure Send",
            "/cloud-api/secure-sends",
            {"filePath": "smoke.pdf", "expiresAt": expires_at.isoformat(), "password": SHARE_PASSWORD},
        )
        link = urlparse(response.get("url", ""))
        check(
            link.netloc == SHARE_HOST and link.path.startswith("/s/"),
            "Share URL did not use the public host",
        )
        share_headers = {"Host": SHARE_HOST}
        self.request("Load share landing page", link.path, headers=share_headers)
        endpoint = "/cloud-api/public/secure-sends/" + quote(link.path.split("/")[-1], safe="") + "/view"
        self.request("Deny passwordless preview", endpoint, expected=401, headers=share_headers)
        data, headers = self.request(
            "Preview shared PDF",
            endpoint,
            headers={**share_headers, "X-Secure-Send-Password": SHARE_PASSWORD},
        )
        check(data == PDF, "Secure Send returned different PDF bytes")
        check(headers.get_content_type() == "application/pdf", "Secure Send did not return a PDF type")
        check(headers.get_content_disposition() == "inline", "Secure Send did not serve the PDF inline")
        self.request(
            "Hide private portal API on the share host",
            "/api/dashboard/me",
            expected=404,
            headers=share_headers,
        )
        self.request(
            "Revoke Secure Send", "/cloud-api/secure-sends/" + quote(response["id"], safe=""),
            expected=204, method="DELETE", headers=self.auth,
        )
        self.request(
            "Deny revoked preview", endpoint, expected=404,
            headers={**share_headers, "X-Secure-Send-Password": SHARE_PASSWORD},
        )

    def run(self, stage):
        self.ready()
        if stage == "ready":
            print("Compose frontend, documentation and both backend routes are ready")
            return
        if stage == "write":
            self.request(
                "Register fixture account",
                "/api/auth/register",
                method="POST",
                body=json.dumps({"username": USERNAME, "password": PASSWORD}),
                headers={"Content-Type": "application/json"},
            )
        self.login()
        dashboard = self.json("Read the authenticated dashboard", "/api/dashboard/me")
        check(dashboard["profile"]["username"] == USERNAME, "Dashboard returned another account")
        if stage == "write":
            self.multipart(
                "Upload Cloud PDF", "/cloud-api/files/upload", "smoke.pdf", PDF, "application/pdf",
                fields=(("folderPath", ""),),
            )
            self.multipart(
                "Upload profile picture", "/api/auth/profile-picture", "smoke.png", PNG, "image/png"
            )
            self.websocket()
            self.share()
        self.read_files()
        print(f"Compose smoke stage {stage} passed through nginx")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", type=int)
    parser.add_argument("stage", choices=("ready", "write", "verify"))
    args = parser.parse_args()
    try:
        Smoke(args.port).run(args.stage)
    except (KeyError, OSError, http.client.HTTPException, RuntimeError, ValueError) as error:
        print(f"Compose smoke failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
