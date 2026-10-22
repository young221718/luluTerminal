#!/usr/bin/env python3
"""Dependency-free checks for this buildless site's authored structure."""
from html.parser import HTMLParser
from pathlib import Path
import hashlib
import subprocess
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"

class SiteParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.references = []
        self.counts = {"server": 0, "tab": 0, "drag": 0, "theme": 0, "mobile": 0}

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            assert attrs["id"] not in self.ids, f"Duplicate ID: {attrs['id']}"
            self.ids.add(attrs["id"])
        for name in ("src", "href"):
            if attrs.get(name):
                self.references.append(attrs[name])
        if attrs.get("target") == "_blank":
            assert {"noopener", "noreferrer"} <= set(attrs.get("rel", "").split()), "Unsafe new-tab link"
        for key, attr in {"server": "data-server", "tab": "data-tab", "drag": "data-drag", "theme": "data-theme-choice", "mobile": "data-mobile-choice"}.items():
            self.counts[key] += attr in attrs
        for reference in ("aria-controls", "aria-labelledby"):
            for value in attrs.get(reference, "").split():
                self.references.append(f"#{value}")

html = (DIST / "index.html").read_text()
parser = SiteParser()
parser.feed(html)
for reference in parser.references:
    url = urlparse(reference)
    if url.scheme or url.netloc:
        assert url.scheme == "https", f"Unexpected external scheme: {reference}"
    elif reference.startswith("#"):
        assert not reference[1:] or reference[1:] in parser.ids, f"Missing fragment: {reference}"
    else:
        path = (DIST / url.path).resolve()
        assert path.is_relative_to(DIST), f"Path leaves dist: {reference}"
        assert path.is_file(), f"Missing local file: {reference}"
assert parser.counts == {"server": 5, "tab": 2, "drag": 2, "theme": 2, "mobile": 3}, parser.counts
assert '<html lang="ko">' in html
assert "웹 데모" in html and "가상" in html
assert "원격 서버와 tmux 세션이 살아 있는 경우" in html
assert "별도 재사용 라이선스가 지정되어 있지 않습니다" in html
assert "#" not in [r for r in parser.references if r.startswith("https:")]
subprocess.run(["node", "--check", str(DIST / "app.js")], check=True)
icon = DIST / "assets/app-icon.png"
assert icon.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
source_icon = ROOT.parent / "Resources" / "AppIcon.png"
if source_icon.is_file():
    assert hashlib.sha256(icon.read_bytes()).digest() == hashlib.sha256(source_icon.read_bytes()).digest(), "App icon changed"
def luminance(color):
    values = [int(color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    return sum(weight * (v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4)
               for weight, v in zip((0.2126, 0.7152, 0.0722), values))

css = (DIST / "style.css").read_text()
contrast_pairs = [
    ("page metadata and footer", "#616d5d", "#fafbf8"),
    ("getting started body", "#616d5d", "#edf2e8"),
    ("demo muted", "#5f6d62", "#f6f8f5"),
    ("demo selected muted", "#5f6d62", "#e6f0e9"),
    ("demo dark muted", "#b0bcb2", "#29322e"),
    ("demo dark selected muted", "#b0bcb2", "#33483e"),
    ("demo dark accent", "#8ac3af", "#33483e"),
    ("demo disk warning", "#8a5b32", "#f6f8f5"),
    ("demo dark disk warning", "#d8b185", "#29322e"),
]
for name, foreground, background in contrast_pairs:
    assert foreground in css and background in css, f"Stale contrast fixture: {name}"
    low, high = sorted((luminance(foreground), luminance(background)))
    ratio = (high + 0.05) / (low + 0.05)
    assert ratio >= 4.5, f"Low contrast: {name}: {ratio:.2f}:1"
print(f"PASS: {len(contrast_pairs)} small-text contrast pairs >= 4.5:1")
print(f"PASS: {len(parser.ids)} unique IDs; {len(parser.references)} links/assets/ARIA references; demo controls; JS syntax; PNG asset")
