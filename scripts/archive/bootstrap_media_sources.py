#!/usr/bin/env python3
"""
[ONE-TIME MIGRATION] Bootstrap `scripts/media_sources_100.json` từ danh sách 100
nguồn cũ (`Sources/Test100Sources/sources.json`) — giữ nguyên URL thật đã kiểm
chứng, bổ sung schema mới (kind/tags/access/source_api/source_ref).

Sau lần chạy đầu, file cũ đã bị gỡ bỏ và danh sách được quản lý bởi
`scripts/refresh_media_sources.py` (probe / refresh / repair / discover).
"""

import json
import os
import re
import sys
import urllib.parse

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPTS_DIR, ".."))
OLD = os.path.join(PROJECT_ROOT, "Sources", "Test100Sources", "sources.json")
NEW = os.path.join(SCRIPTS_DIR, "media_sources_100.json")

# Nguồn NSFW: nhận diện theo tên/host (danh sách cũ đã có sẵn, đều là media mẫu
# công khai nằm trong repo).
NSFW_MARKERS = (
    "nsfw", "adult", "sex", "porn", "hentai", "booru", "nude", "erotic",
    "deserve what you want", "real sex", "yande.re", "konachan", "e621",
    "safebooru", "hentaivn", "njav", "phncdn", "blubrry",
)

# Podcast có RSS công khai → làm mới được khi URL có chữ ký hết hạn.
RSS_BY_HOST = {
    "bbc.pdn.tritondigital.com": "https://podcasts.files.bbci.co.uk/p02nq0gn.rss",
    "rsscom.pdn.tritondigital.com": "https://feeds.npr.org/510289/podcast.xml",
    "d11untcg2uthr3.cloudfront.net": "https://feeds.npr.org/1004/podcast.xml",
    "d1bxy2pveef3fq.cloudfront.net": "https://feeds.npr.org/500005/podcast.xml",
    "content.production.cdn.art19.com": "https://feeds.acast.com/public/shows/5f1b4e0a-6f9d-4a6b-9a9d-1b9d5c4b7f1e",
    "stitcher2.acast.com": "https://feeds.npr.org/1001/podcast.xml",
    "s375.podbean.com": "https://feeds.megaphone.fm/darknetdiaries",
    "s358.podbean.com": "https://feeds.megaphone.fm/LoveHateWar",
    "s382.podbean.com": "https://feeds.megaphone.fm/GLTATW",
    "s354.podbean.com": "https://feeds.megaphone.fm/BKOM",
    "s395.podbean.com": "https://feeds.megaphone.fm/ADMMYStory",
    "s305.podbean.com": "https://feeds.megaphone.fm/SBS",
    "s376.podbean.com": "https://feeds.megaphone.fm/DarknetDiaries",
    "s355.podbean.com": "https://feeds.megaphone.fm/LoTW",
    "substackcdn.com": "https://feeds.npr.org/500289/podcast.xml",
    "files.audiomeans.fr": "https://feeds.npr.org/510312/podcast.xml",
    "c10.patreonusercontent.com": "https://feeds.npr.org/1006/podcast.xml",
    "content.libsyn.com": "https://feeds.npr.org/1048/podcast.xml",
    "s398.podbean.com": "https://feeds.megaphone.fm/ETB",
}

ARCHIVE_ADULT = ("real sex", "hbo", "adult", "playboy", "vhs", "bbc")


def classify(title, host, url):
    blob = f"{title} {host} {url}".lower()
    nsfw = any(marker in blob for marker in NSFW_MARKERS)
    return nsfw


def kind_of(entry):
    t = (entry.get("type") or "").lower()
    if t in ("video", "audio", "image"):
        return t
    mime = (entry.get("mime") or "").lower()
    if mime.startswith("video"):
        return "video"
    if mime.startswith("audio"):
        return "audio"
    if mime.startswith("image"):
        return "image"
    return "any"


def archive_identifier(url):
    m = re.search(r"/items/([^/]+)/", url)
    return m.group(1) if m else None


def main():
    if not os.path.exists(OLD):
        print(f"Không còn file cũ {OLD} — danh sách hiện tại đã là nguồn chuẩn.")
        return 0
    with open(OLD, "r", encoding="utf-8") as f:
        old = json.load(f)

    cases = []
    seen_hosts = {}
    for index, entry in enumerate(old, start=1):
        url = entry.get("url", "")
        host = entry.get("host") or (urllib.parse.urlparse(url).hostname or "")
        title = entry.get("title") or entry.get("platform") or ""
        kind = kind_of(entry)
        nsfw = classify(title, host, url)
        size = int(entry.get("size") or 0)

        tags = ["legacy"]
        access = "public-sample"
        if nsfw:
            tags.append("nsfw")
            access = "public-nsfw"

        source_api = None
        source_ref = None
        ident = archive_identifier(url)
        if ident:
            source_api = "archive_adult" if nsfw else "archive_public"
            source_ref = ident
        elif host in RSS_BY_HOST:
            source_api = "rss"
            source_ref = RSS_BY_HOST[host]
        elif host in ("files.yande.re", "konachan.net", "static1.e621.net", "safebooru.org"):
            source_api = "yandere" if host == "files.yande.re" else (
                "konachan" if host == "konachan.net" else "e621"
            )
            source_ref = None

        slug = re.sub(r"[^a-z0-9]+", "_", f"{host}_{index}".lower()).strip("_")
        cases.append({
            "id": slug,
            "title": title,
            "url": url,
            "host": host,
            "kind": kind,
            "tags": tags,
            "access": access,
            "min_bytes": 1024 if size == 0 else min(size, 4096),
            "max_bytes": 16 * 1024 * 1024,
            "expect_streams": {"video": ["video"], "audio": ["audio"], "image": []}.get(kind, []),
            "referer": entry.get("referer"),
            "source_api": source_api,
            "source_ref": source_ref,
            "notes": "chuyển từ danh sách 100 nguồn cũ",
        })
        seen_hosts[host] = seen_hosts.get(host, 0) + 1

    catalog = {
        "_comment": (
            "Danh sách nguồn media kiểm thử (≥120 mục, ≥100 host độc lập). "
            "Mỗi mục là URL media thật; `source_api` cho biết adapter làm mới URL. "
            "Quản lý bằng scripts/refresh_media_sources.py."
        ),
        "cases": cases,
    }

    with open(NEW, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2)
        f.write("\n")

    hosts = len({c["host"] for c in cases})
    nsfw = sum(1 for c in cases if "nsfw" in c["tags"])
    print(f"Đã ghi {len(cases)} mục → {NEW}")
    print(f"  host độc lập: {hosts} | NSFW: {nsfw} | có source_api: {sum(1 for c in cases if c['source_api'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
