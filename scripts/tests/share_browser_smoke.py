"""Exercise the anonymous Secure Send UI against the running Compose stack."""
import re
from urllib.parse import urlsplit

from playwright.sync_api import expect, sync_playwright


def expect_pdf(dialog, page, name):
    preview = dialog.locator(f'iframe[title="{name}"]')
    expect(preview).to_be_visible()
    expect(preview).to_have_attribute("src", re.compile(r"^blob:"))
    mime, header = page.evaluate(
        """async (url) => {
            const response = await fetch(url);
            const pdf = await response.blob();
            return [pdf.type, await pdf.slice(0, 5).text()];
        }""",
        preview.get_attribute("src"),
    )
    if (mime, header) != ("application/pdf", "%PDF-"):
        raise RuntimeError("The guest preview did not load a PDF blob")


def button(container, label):
    return container.get_by_role("button").filter(has_text=re.compile(rf"^\s*{re.escape(label)}\s*$"))


def close_preview(dialog):
    button(dialog, "Close").click()
    expect(dialog).to_be_hidden()


def check_share_ui(origin, file_path, folder_path, password, expected_pdf, revoke):
    with sync_playwright() as playwright:
        host = urlsplit(origin).hostname
        browser = playwright.chromium.launch(
            channel="chromium",
            args=[f"--host-resolver-rules=MAP {host} 127.0.0.1", "--no-proxy-server"],
        )
        context = browser.new_context(**playwright.devices["Pixel 7"])
        page = context.new_page()
        page.set_default_timeout(10000)
        page.goto(origin + file_path, wait_until="commit")
        field = page.get_by_label("Password", exact=True)
        field.fill("incorrect fixture password")
        preview_button = button(page, "Preview")
        dialog = page.get_by_role("dialog")
        preview_button.click()
        expect(page.get_by_role("alert")).to_have_text("That password is not correct.")
        expect(dialog).to_be_hidden()

        field.fill(password)
        preview_button.click()
        expect_pdf(dialog, page, "smoke.pdf")
        with page.expect_download() as download:
            button(dialog, "Download").click()
        if download.value.path().read_bytes() != expected_pdf:
            raise RuntimeError("The guest download did not match the uploaded PDF")
        close_preview(dialog)

        # Request private routes without owner credentials, using the same browser origin.
        for path in ("/dashboard", "/api/dashboard/me"):
            status = page.evaluate("async (path) => (await fetch(path)).status", path)
            if status != 404:
                raise RuntimeError(f"The share host exposed {path} (HTTP {status})")
        revoke()
        page.reload(wait_until="commit")
        expect(page.get_by_role("heading", name="Link unavailable")).to_be_visible()

        page.goto(origin + folder_path, wait_until="commit")
        button(page, "report.pdf").click()
        expect_pdf(dialog, page, "report.pdf")
        close_preview(dialog)
        button(page, "note.txt").click()
        expect(dialog.get_by_text("Secure Send browser smoke fixture")).to_be_visible()
        close_preview(dialog)
        button(page, "icon.png").click()
        image = dialog.get_by_role("img", name="icon.png", exact=True)
        expect(image).to_be_visible()
        image.evaluate("element => element.decode()")
        context.close()
        browser.close()
