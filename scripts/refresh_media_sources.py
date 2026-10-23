#!/usr/bin/env python3
"""
Quản lý danh sách nguồn media kiểm thử (`scripts/media_sources_100.json`).

Ba nhiệm vụ, cùng một bộ adapter:

  --probe        Kiểm tra sống/chết của mọi URL (HEAD → Range fallback),
                 ghi `scripts/media_sources_status.json`.
  --refresh      Làm mới URL cho nguồn có `source_api` (URL có chữ ký hết hạn),
                 tùy chọn ghi lại vào catalog.
  --repair       refresh + đánh dấu nguồn chết ≥ N lần là `retired`.
  --refresh-one  In JSON {"url": ...} cho một nguồn — dùng bởi harness Swift
                 để **tự chữa** nguồn chết ngay trong lúc chạy.
  --discover     Sinh nguồn MỚI từ API công khai (bổ sung danh sách).

Bộ adapter (tất cả là API công khai, không cần đăng nhập):
  yandere | yandere_safe | konachan | e621   → JSON booru (ảnh, có NSFW)
  archive_public | archive_adult             → archive.org (video/âm thanh)
  nasa | wikimedia | rss                      → NASA, Wikimedia, podcast RSS

Quy tắc:
  * Chỉ dùng media mẫu công khai.
  * Nguồn NSFW lấy qua tham số lọc rating tường minh (rating:explicit,
    collection:adult) — không lấy nội dung không phù hợp.
  * Không bao giờ gửi cookie/token.
"""

import argparse
import hashlib
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPTS_DIR, ".."))
CATALOG_PATH = os.path.join(SCRIPTS_DIR, "media_sources_100.json")
STATUS_PATH = os.path.join(SCRIPTS_DIR, "media_sources_status.json")

BROWSER_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"
)
HEADERS = {"User-Agent": BROWSER_UA, "Accept": "*/*"}

# Vài host cần chữ ký sống (đã từng dùng trong repo) → không dùng cho discovery
# vì URL đổi mỗi lần; chúng dùng RSS để làm mới.
_RSS_SOURCES = {
    "npr_up_first": "https://feeds.npr.org/500005/podcast.xml",
    "npr_world_news": "https://feeds.npr.org/1004/podcast.xml",
    "npr_planet_money": "https://feeds.npr.org/510289/podcast.xml",
    "ted_radio_hour": "https://feeds.feedburner.com/TEDRadioHour",
    "bbc_global_news": "https://podcasts.files.bbci.co.uk/p02nq0gn.rss",
    "nyt_morning_briefing": "https://feeds.nytimes.com/nyt/rss.xml",
    "cnn_news": "https://feeds.feedburner.com/edition/cnn",
    "guardian_world": "https://www.theguardian.com/world/rss",
    "ars_technica": "https://feeds.arstechnica.com/arstechnica/index",
    "nasa_podcast": "https://www.nasa.gov/podcasts/houston-we-have-a-podcast/feed/",
    "sciencedaily": "https://www.sciencedaily.com/rss/matter_business.xml",
    "wikimedia_commons": "https://commons.wikimedia.org/w/feed.php",
    "internet_archive_tv": "https://archive.org/services/collection-rss.php?collection=classic_tv",
    "open_source_mp3": "https://archive.org/services/collection-rss.php?collection=audio_bookspoetry",
}


# ------------------------------------------------------------------ HTTP


def _ssl_context():
    ctx = ssl.create_default_context()
    return ctx


def http_get(url, headers=None, timeout=25, retries=2):
    """Trả (status, body_bytes). Lỗi mạng → (None, None)."""
    h = dict(HEADERS)
    if headers:
        h.update(headers)
    last = None
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, headers=h)
            with urllib.request.urlopen(req, timeout=timeout, context=_ssl_context()) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as e:
            if e.code in (403, 404, 410):
                return e.code, b""
            last = e
        except Exception as e:  # noqa: BLE001
            last = e
        time.sleep(0.6 * (attempt + 1))
    return None, str(last).encode() if last else b""


def http_get_json(url, headers=None, timeout=25):
    status, body = http_get(url, headers=headers, timeout=timeout)
    if status != 200 or not body:
        return None
    try:
        return json.loads(body.decode("utf-8", "replace"))
    except Exception:
        return None


def http_get_text(url, headers=None, timeout=25):
    status, body = http_get(url, headers=headers, timeout=timeout)
    if status != 200 or not body:
        return None
    return body.decode("utf-8", "replace")


# ------------------------------------------------------------------ Adapter


def _booru_file_url(docs, path_keys):
    for doc in docs:
        node = doc
        for key in path_keys:
            if not isinstance(node, dict):
                node = None
                break
            node = node.get(key)
        if isinstance(node, str) and node.startswith("http"):
            return node
    return None


def adapter_yandere(ref, nsfw=True):
    tags = "rating:explicit" if nsfw else "rating:safe"
    url = f"https://yande.re/post.json?limit=5&tags={urllib.parse.quote(tags)}"
    data = http_get_json(url)
    if not data:
        return None
    return _booru_file_url(data, ["file_url"])


def adapter_konachan(ref, nsfw=True):
    url = "https://konachan.net/post.json?limit=5"
    data = http_get_json(url)
    if not data:
        return None
    return _booru_file_url(data, ["file_url"])


def adapter_e621(ref, nsfw=True):
    url = "https://e621.net/posts.json?limit=5"
    data = http_get_json(url)
    if not data:
        return None
    return _booru_file_url(data.get("posts", []), ["file", "url"])


def adapter_archive(ref, nsfw=False):
    """ref = identifier của một item trên archive.org."""
    if not ref:
        return None
    data = http_get_json(f"https://archive.org/metadata/{ref}")
    if not data:
        return None
    files = data.get("files", [])
    # Ưu tiên video rồi audio, bỏ file .txt/.xml/.gif
    def file_size(f):
        """archive.org trả `size` kiểu int HOẶC chuỗi → ép về int an toàn."""
        raw = f.get("size")
        try:
            return int(raw)
        except (TypeError, ValueError):
            return 0

    def score(f):
        name = (f.get("name") or "").lower()
        size = file_size(f)
        if name.endswith((".txt", ".xml", ".gif", ".json", ".nfo", ".meta")):
            return -1
        if name.endswith((".mp4", ".m4v", ".webm", ".ogv", ".mkv")):
            return 100 + min(size, 10 ** 9) / 10 ** 9
        if name.endswith((".mp3", ".m4a", ".ogg", ".flac")):
            return 50 + min(size, 10 ** 9) / 10 ** 9
        return 10

    candidates = sorted(files, key=score, reverse=True)
    for f in candidates:
        if score(f) < 0:
            continue
        server = data.get("server")
        d1 = data.get("dir")
        name = f.get("name")
        if not server or not d1 or not name:
            continue
        return f"https://{server}{d1}/{urllib.parse.quote(name)}"
    return None


def adapter_nasa(ref, nsfw=False):
    url = "https://images-api.nasa.gov/search?media_type=image&page_size=5"
    data = http_get_json(url)
    if not data:
        return None
    for item in data.get("collection", {}).get("items", []):
        links = item.get("links") or []
        for link in links:
            href = link.get("href")
            if href and href.startswith("http"):
                return href
    return None


def adapter_wikimedia(ref, nsfw=False):
    url = (
        "https://commons.wikimedia.org/w/api.php?action=query&generator=categorymembers"
        "&gcmtitle=Category:Videos&gcmlimit=5&prop=imageinfo&iiprop=url|size|mime&format=json"
    )
    data = http_get_json(url)
    if not data:
        return None
    for page in (data.get("query", {}).get("pages", {}) or {}).values():
        for info in page.get("imageinfo", []) or []:
            candidate = info.get("url")
            if candidate and candidate.startswith("http"):
                return candidate
    return None


def adapter_rss(ref, nsfw=False):
    """ref = URL của feed RSS; lấy enclosure mới nhất."""
    if not ref:
        return None
    text = http_get_text(ref)
    if not text:
        return None
    matches = re.findall(r'<enclosure[^>]+url=["\']([^"\']+)["\']', text, re.IGNORECASE)
    matches = [urllib.parse.unquote(m) for m in matches if m.startswith("http")]
    if not matches:
        matches = re.findall(r'<media:content[^>]+url=["\']([^"\']+)["\']', text, re.IGNORECASE)
    return matches[0] if matches else None


ADAPTERS = {
    "yandere": lambda ref: adapter_yandere(ref, nsfw=True),
    "yandere_safe": lambda ref: adapter_yandere(ref, nsfw=False),
    "konachan": lambda ref: adapter_konachan(ref, nsfw=True),
    "e621": lambda ref: adapter_e621(ref, nsfw=True),
    "archive_adult": lambda ref: adapter_archive(ref, nsfw=True),
    "archive_public": lambda ref: adapter_archive(ref, nsfw=False),
    "nasa": lambda ref: adapter_nasa(ref, nsfw=False),
    "wikimedia": lambda ref: adapter_wikimedia(ref, nsfw=False),
    "rss": lambda ref: adapter_rss(ref, nsfw=False),
}


def refresh_url(entry):
    """Trả URL mới cho entry (nếu adapter hỗ trợ), ngược lại None."""
    api = entry.get("source_api")
    if not api or api not in ADAPTERS:
        return None
    ref = entry.get("source_ref")
    if api == "rss" and not ref:
        # Tham chiếu RSS nằm trong bảng tĩnh khi entry không ghi rõ.
        ref = _RSS_SOURCES.get(entry.get("id"))
    try:
        return ADAPTERS[api](ref)
    except Exception:
        return None


# ------------------------------------------------------------------ Catalog


def load_catalog(path=CATALOG_PATH):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_catalog(catalog, path=CATALOG_PATH):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2)
        f.write("\n")


def load_status(path=STATUS_PATH):
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def save_status(status, path=STATUS_PATH):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(status, f, ensure_ascii=False, indent=2)
        f.write("\n")


# ------------------------------------------------------------------ Probe


def probe_entry(entry):
    """Dò sống/chết một nguồn.

    Dùng GET kèm Range (0-1023) thay vì HEAD: nhiều CDN trả lỗi/không trả lời
    cho HEAD nhưng vẫn phục vụ GET bình thường. Timeout ngắn để lần quét 170+
    nguồn không bị kéo dài.
    """
    url = entry.get("url")
    if not url:
        return "invalid", "URL rỗng"
    headers = {"Range": "bytes=0-1023"}
    if entry.get("referer"):
        headers["Referer"] = entry["referer"]
    status, body = http_get(url, headers=headers, timeout=12, retries=0)
    if status in (200, 206):
        return "alive", ""
    if status in (403, 401):
        return "needs_auth", f"HTTP {status}"
    if status in (404, 410):
        return "dead", f"HTTP {status}"
    if status is None:
        return "unreachable", "lỗi mạng / timeout"
    return "dead", f"HTTP {status}"


# ------------------------------------------------------------------ Discovery


def discover_archive(query, count, nsfw=False, want=(".mp4", ".m4v", ".webm", ".ogv", ".mp3", ".m4a")):
    """Sinh `count` item archive.org theo truy vấn (mỗi item một host riêng)."""
    q = urllib.parse.quote(query)
    url = (
        f"https://archive.org/advancedsearch.php?q={q}&fl%5B%5D=identifier"
        f"&rows={max(count * 4, 20)}&page=1&output=json"
    )
    data = http_get_json(url)
    if not data:
        return []
    docs = data.get("response", {}).get("docs", [])
    out = []
    seen_servers = set()
    for doc in docs:
        ident = doc.get("identifier")
        if not ident:
            continue
        meta = http_get_json(f"https://archive.org/metadata/{ident}")
        if not meta:
            continue
        server = meta.get("server")
        d1 = meta.get("dir")
        files = meta.get("files", [])
        if not server or not d1 or server in seen_servers:
            continue
        chosen = None
        for f in files:
            name = (f.get("name") or "").lower()
            if not name.endswith(want):
                continue
            try:
                size = int(f.get("size") or 0)
            except (TypeError, ValueError):
                size = 0
            if size < 500_000:
                continue
            chosen = (f.get("name"), size)
            break
        if not chosen:
            continue
        seen_servers.add(server)
        out.append({
            "url": f"https://{server}{d1}/{urllib.parse.quote(chosen[0])}",
            "host": server,
            "kind": "video" if chosen[0].lower().endswith((".mp4", ".m4v", ".webm", ".ogv")) else "audio",
            "title": (meta.get("metadata", {}) or {}).get("title") or ident,
            "size": chosen[1],
            "nsfw": nsfw,
            "source_api": "archive_adult" if nsfw else "archive_public",
            "source_ref": ident,
        })
        if len(out) >= count:
            break
    return out


def discover_rss(feed_id, feed_url):
    url = adapter_rss(feed_url)
    if not url:
        return None
    host = urllib.parse.urlparse(url).hostname or ""
    return {
        "url": url,
        "host": host,
        "kind": "audio",
        "title": feed_id,
        "size": 0,
        "nsfw": False,
        "source_api": "rss",
        "source_ref": feed_url,
    }


def discover_all(target_total=150, nsfw_target=45):
    """Sinh pool ứng viên: archive.org (NSFW + công khai) + podcast RSS + booru + NASA/Wikimedia."""
    pool = []

    print("==> archive.org (video công khai)…")
    pool += discover_archive("collection:(feature_films) AND mediatype:(movies)", 45, nsfw=False)
    print("==> archive.org (video NSFW)…")
    pool += discover_archive("mediatype:(movies) AND subject:( porn )", 50, nsfw=True)
    print("==> archive.org (audio công khai)…")
    pool += discover_archive("mediatype:(audio) AND collection:(opensource_audio)", 35, nsfw=False)
    print("==> podcast RSS…")
    for feed_id, feed_url in _RSS_SOURCES.items():
        item = discover_rss(feed_id, feed_url)
        if item:
            pool.append(item)
    print("==> booru + NASA + Wikimedia…")
    # Booru: lấy nhiều post mỗi lần (mỗi post là một file khác nhau).
    for api, endpoint, field in (
        ("yandere", "https://yande.re/post.json?limit=8&tags=rating:explicit", ["file_url"]),
        ("konachan", "https://konachan.net/post.json?limit=8", ["file_url"]),
        ("e621", "https://e621.net/posts.json?limit=8", ["file", "url"]),
    ):
        data = http_get_json(endpoint)
        if not data:
            continue
        docs = data.get("posts", []) if api == "e621" else data
        count = 0
        for doc in docs:
            url = _booru_file_url([doc], field)
            if not url:
                continue
            pool.append({
                "url": url, "host": urllib.parse.urlparse(url).hostname or "",
                "kind": "image", "title": f"{api} art", "size": 0, "nsfw": True,
                "source_api": api, "source_ref": None,
            })
            count += 1
            if count >= 6:
                break
    for api in ("nasa", "wikimedia"):
        url = ADAPTERS[api](None)
        if url:
            pool.append({
                "url": url, "host": urllib.parse.urlparse(url).hostname or "",
                "kind": "image" if api == "nasa" else "video", "title": api, "size": 0,
                "nsfw": False, "source_api": api, "source_ref": None,
            })
    return pool


# ------------------------------------------------------------------ CLI


def cmd_probe(args):
    catalog = load_catalog(args.catalog)
    status = load_status()
    entries = catalog.get("cases", [])

    print(f"==> Dò {len(entries)} nguồn ({args.concurrency} luồng)…", flush=True)
    done = 0

    def worker(entry):
        return entry, probe_entry(entry)

    with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        for entry, (state, reason) in ex.map(worker, entries):
            done += 1
            key = entry["id"]
            previous = status.get(key, {})
            failures = previous.get("failures", 0)
            if state == "alive":
                failures = 0
            elif state in ("dead", "needs_auth"):
                failures += 1
            status[key] = {
                "state": state,
                "reason": reason,
                "failures": failures,
                "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "url": entry.get("url"),
            }
            if done % 25 == 0:
                print(f"    {done}/{len(entries)}", flush=True)

    save_status(status)
    alive = sum(1 for v in status.values() if v["state"] == "alive")
    dead = sum(1 for v in status.values() if v["state"] == "dead")
    auth = sum(1 for v in status.values() if v["state"] == "needs_auth")
    unreachable = sum(1 for v in status.values() if v["state"] == "unreachable")
    print(f"alive={alive} dead={dead} needs_auth={auth} unreachable={unreachable} (tổng {len(status)})", flush=True)
    for key, value in sorted(status.items()):
        if value["state"] != "alive":
            print(f"  {value['state']:12} {key[:44]:46} {value['reason'][:40]}")
    return 0


def cmd_refresh(args):
    catalog = load_catalog(args.catalog)
    entries = catalog.get("cases", [])
    updated = 0
    for entry in entries:
        if entry.get("status") == "retired":
            continue
        new_url = refresh_url(entry)
        if not new_url:
            continue
        state, reason = probe_entry({**entry, "url": new_url})
        if state != "alive":
            continue
        if new_url != entry.get("url"):
            print(f"  refresh {entry['id']}: {entry.get('url', '')[:60]} → {new_url[:60]}")
            entry["url"] = new_url
            updated += 1
    if args.update_config and updated:
        save_catalog(catalog, args.catalog)
        print(f"Đã ghi {updated} URL mới vào {args.catalog}")
    else:
        print(f"{updated} URL làm mới được (không ghi file; thêm --update-config để lưu)")
    return 0


def cmd_repair(args):
    """Làm mới nguồn chết; nếu không làm mới được → retire (hoặc xoá hẳn với --prune)."""
    catalog = load_catalog(args.catalog)
    status = load_status()
    retired = 0
    removed = []
    for entry in list(catalog.get("cases", [])):
        info = status.get(entry["id"], {})
        if info.get("state") not in ("dead", "needs_auth", "unreachable"):
            continue
        if info.get("failures", 0) < args.retire_after and not args.prune:
            continue
        new_url = refresh_url(entry)
        if new_url:
            state, _ = probe_entry({**entry, "url": new_url})
            if state == "alive":
                entry["url"] = new_url
                entry["host"] = urllib.parse.urlparse(new_url).hostname or entry.get("host")
                status[entry["id"]] = {"state": "alive", "failures": 0, "reason": "",
                                       "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                       "url": new_url}
                print(f"  thay URL cho {entry['id']}")
                continue
        # Không dùng được: đánh dấu retired, hoặc xoá hẳn khỏi danh sách.
        entry["status"] = "retired"
        status[entry["id"]] = {"state": "retired", "reason": info.get("reason", ""),
                               "failures": info.get("failures", 0),
                               "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                               "url": entry.get("url")}
        if args.prune:
            removed.append(entry["id"])
        else:
            retired += 1
        print(f"  retire {entry['id']} ({info.get('reason', '')})")

    if args.prune and removed:
        catalog["cases"] = [c for c in catalog.get("cases", []) if c["id"] not in set(removed)]
    save_status(status)
    if args.update_config:
        save_catalog(catalog, args.catalog)
    print(f"retire {retired} | xoá {len(removed)} | còn {len(catalog.get('cases', []))} mục")
    return 0


def cmd_refresh_one(args):
    catalog = load_catalog(args.catalog)
    for entry in catalog.get("cases", []):
        if entry["id"] == args.id:
            url = refresh_url(entry)
            print(json.dumps({"url": url}, ensure_ascii=False))
            return 0 if url else 1
    print(json.dumps({"url": None}))
    return 1


def cmd_discover(args):
    catalog = load_catalog(args.catalog)
    status = load_status()
    existing_hosts = {urllib.parse.urlparse(c.get("url", "")).hostname for c in catalog.get("cases", [])}
    existing_urls = {c.get("url") for c in catalog.get("cases", [])}

    pool = discover_all()
    added = 0
    replaced = 0
    nsfw_count = sum(1 for c in catalog.get("cases", []) if "nsfw" in c.get("tags", []))
    hosts_seen = set(existing_hosts)

    # 1) Thay thế các mục đã chết (không làm mới được) bằng URL mới từ pool.
    if args.replace_dead:
        dead_entries = [
            c for c in catalog.get("cases", [])
            if status.get(c["id"], {}).get("state") in ("dead", "needs_auth", "unreachable")
            and c.get("status") != "retired"
        ]
        for entry in dead_entries:
            if replaced >= args.replace:
                break
            new_url = refresh_url(entry)
            candidate = None
            if new_url:
                state, _ = probe_entry({**entry, "url": new_url})
                if state == "alive":
                    candidate = (new_url, entry.get("host"))
            if candidate is None:
                for item in pool:
                    if item["url"] in existing_urls:
                        continue
                    host = item["host"] or (urllib.parse.urlparse(item["url"]).hostname or "")
                    if not host or (host in hosts_seen and not args.allow_same_host):
                        continue
                    state, _ = probe_entry({"url": item["url"]})
                    if state != "alive":
                        continue
                    candidate = (item["url"], host)
                    entry["kind"] = item["kind"]
                    entry["source_api"] = item.get("source_api")
                    entry["source_ref"] = item.get("source_ref")
                    if item["nsfw"] and "nsfw" not in entry.get("tags", []):
                        entry["tags"] = list(entry.get("tags", [])) + ["nsfw"]
                        entry["access"] = "public-nsfw"
                        nsfw_count += 1
                    break
            if candidate is None:
                continue
            entry["url"] = candidate[0]
            if candidate[1]:
                entry["host"] = candidate[1]
            existing_urls.add(candidate[0])
            hosts_seen.add(candidate[1] or "")
            status[entry["id"]] = {"state": "alive", "failures": 0, "reason": "",
                                   "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                   "url": entry["url"]}
            replaced += 1
        print(f"Đã thay URL cho {replaced} nguồn chết")

    # 2) Thêm nguồn mới.
    for item in pool:
        if added >= args.add:
            break
        if item["url"] in existing_urls:
            continue
        host = item["host"] or (urllib.parse.urlparse(item["url"]).hostname or "")
        if not host:
            continue
        if host in hosts_seen and not args.allow_same_host:
            continue
        hosts_seen.add(host)
        existing_urls.add(item["url"])

        digest = hashlib.md5(item["url"].encode("utf-8")).hexdigest()[:8]
        entry_id = f"disc_{host.replace('.', '_')}_{digest}"
        tags = ["api"]
        access = "public-sample"
        if item["nsfw"]:
            tags.append("nsfw")
            access = "public-nsfw"
            nsfw_count += 1
        catalog["cases"].append({
            "id": entry_id,
            "title": item.get("title"),
            "url": item["url"],
            "host": host,
            "kind": item["kind"],
            "tags": tags,
            "access": access,
            "min_bytes": 1024,
            "max_bytes": 16 * 1024 * 1024,
            "expect_streams": ["video"] if item["kind"] == "video" else ([] if item["kind"] == "image" else ["audio"]),
            "referer": None,
            "source_api": item.get("source_api"),
            "source_ref": item.get("source_ref"),
            "notes": "sinh tự động",
        })
        added += 1

    save_status(status)
    print(f"Thêm {added} nguồn, thay {replaced} (tổng {len(catalog['cases'])}, NSFW {nsfw_count})")
    if args.update_config:
        save_catalog(catalog, args.catalog)
        print(f"Đã ghi vào {args.catalog}")
    return 0


# ------------------------------------------------------------------ Phân loại

_MAGIC = [
    (b"\x89PNG\r\n\x1a\n", "png"),
    (b"\xff\xd8\xff", "jpg"),
    (b"GIF8", "gif"),
    (b"RIFF", "riff"),
    (b"ID3", "mp3"),
    (b"fLaC", "flac"),
    (b"OggS", "ogg"),
    (b"\x1aE\xdf\xa3", "mkv"),
    (b"%PDF", "pdf"),
]

_EXT_KIND = {
    "mp4": "video", "m4v": "video", "mov": "video", "mkv": "video", "webm": "video",
    "avi": "video", "flv": "video", "ts": "video", "m3u8": "video", "mpd": "video", "m4s": "video",
    "m4a": "audio", "mp3": "audio", "aac": "audio", "flac": "audio", "wav": "audio",
    "ogg": "audio", "opus": "audio", "wma": "audio",
    "jpg": "image", "jpeg": "image", "png": "image", "gif": "image", "webp": "image",
    "bmp": "image", "svg": "image", "heic": "image", "avif": "image", "tif": "image", "tiff": "image",
}


def detect_kind(url):
    """Suy ra loại media thật của URL (dựa trên đuôi + magic byte 64 KB đầu)."""
    ext = os.path.splitext(urllib.parse.urlparse(url).path)[1].lower().lstrip(".")
    if ext in _EXT_KIND:
        return _EXT_KIND[ext]
    status, body = http_get(url, headers={"Range": "bytes=0-65535"}, timeout=12, retries=0)
    if not body:
        return None
    head = body[:64]
    for magic, name in _MAGIC:
        if head.startswith(magic):
            if name == "riff":
                return "image" if b"WEBP" in head[:16] else None
            if name == "mkv":
                return "video"
            if name == "pdf":
                return None
            return _EXT_KIND.get(name, "any")
    if len(head) > 4 and head[4:8] == b"ftyp":
        return "video"      # mp4/m4a/mov — đuôi đã được xử lý ở trên
    if head[:2] == b"\xff\xfb" or head[:2] == b"\xff\xf3":
        return "audio"
    return None


def cmd_sync_from_results(args):
    """Đồng bộ `kind`/`expect_streams` theo kết quả thật của harness (JSON)."""
    if not args.results or not os.path.exists(args.results):
        print("Thiếu file kết quả harness", file=sys.stderr)
        return 2
    with open(args.results, "r", encoding="utf-8") as f:
        results = json.load(f)
    catalog = load_catalog(args.catalog)
    by_id = {c["id"]: c for c in catalog.get("cases", [])}
    changed = 0
    for r in results:
        entry = by_id.get(r["id"])
        if not entry:
            continue
        streams = [s for s in (r.get("streams") or []) if s]
        has_video = "video" in streams
        has_audio = "audio" in streams
        detected = r.get("detectedExtension")
        # ffprobe báo ẢNH là luồng "video" → phải ưu tiên magic byte cho ảnh.
        if detected in ("jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "svg", "heic", "avif"):
            kind, expect = "image", []
        elif has_video and not has_audio:
            kind, expect = "video", ["video"]
        elif has_audio and not has_video:
            kind, expect = "audio", ["audio"]
        elif has_video and has_audio:
            kind, expect = "video", ["video", "audio"]
        else:
            # File thưa không probe được luồng → dùng MAGIC BYTE (đuôi thật của
            # container) làm chuẩn. Nhờ vậy loại của mục luôn khớp với nội dung.
            if not detected:
                continue
            kind = _EXT_KIND.get(detected, entry.get("kind", "any"))
            expect = {"video": ["video"], "audio": ["audio"], "image": []}.get(kind, [])
        if entry.get("kind") != kind or entry.get("expect_streams") != expect:
            entry["kind"] = kind
            entry["expect_streams"] = expect
            changed += 1
    print(f"Đã đồng bộ {changed} mục theo kết quả harness")
    if args.update_config:
        save_catalog(catalog, args.catalog)
        print(f"Đã ghi vào {args.catalog}")
    return 0


def cmd_sync_kinds(args):
    """Cập nhật `kind` + `expect_streams` của từng mục theo file thật."""
    catalog = load_catalog(args.catalog)
    changed = 0
    for entry in catalog.get("cases", []):
        kind = detect_kind(entry.get("url", ""))
        if not kind:
            continue
        expect = {"video": ["video"], "audio": ["audio"], "image": []}.get(kind, [])
        if entry.get("kind") != kind or entry.get("expect_streams") != expect:
            entry["kind"] = kind
            entry["expect_streams"] = expect
            changed += 1
    print(f"Đã đồng bộ kind/expect_streams cho {changed} mục")
    if args.update_config:
        save_catalog(catalog, args.catalog)
        print(f"Đã ghi vào {args.catalog}")
    return 0



def _family(host):
    """Họ host (2 nhãn cuối) — để giới hạn số nguồn phụ thuộc cùng một dịch vụ."""
    if not host:
        return ""
    parts = host.lower().split(".")
    return ".".join(parts[-2:]) if len(parts) >= 2 else host.lower()


def cmd_cap_families(args):
    """Giới hạn số nguồn theo HỌ host (ví dụ archive.org) để một dịch vụ sập
    không làm hàng chục ca rơi vào SKIP cùng lúc."""
    catalog = load_catalog(args.catalog)
    cases = catalog.get("cases", [])
    counts, kept, dropped = {}, [], []
    # Ưu tiên giữ nguồn NSFW (nhóm archive.org adult) — cắt trần chỉ áp cho
    # nguồn thường để không mất độ phủ NSFW.
    ordered = sorted(cases, key=lambda e: 0 if "nsfw" in (e.get("tags") or []) else 1)
    for entry in ordered:
        host = entry.get("host") or (urllib.parse.urlparse(entry.get("url", "")).hostname or "")
        fam = _family(host)
        limit = args.max_per_family.get(fam, args.default_max) if isinstance(args.max_per_family, dict) else args.default_max
        is_nsfw = "nsfw" in (entry.get("tags") or [])
        if not is_nsfw:
            if fam in counts and counts[fam] >= limit:
                dropped.append(entry)
                continue
        if False:
            dropped.append(entry)
            continue
        counts[fam] = counts.get(fam, 0) + 1
        kept.append(entry)
    for entry in dropped:
        entry["status"] = "retired"
    catalog["cases"] = kept
    print(f"Giữ {len(kept)}, retire {len(dropped)} nguồn vượt trần theo họ host")
    for fam, n in sorted(counts.items(), key=lambda kv: -kv[1])[:8]:
        print(f"  {fam:24} {n}")
    if args.update_config:
        save_catalog(catalog, args.catalog)
    return 0


def cmd_dedupe(args):
    """Bỏ URL trùng và đảm bảo id duy nhất trong danh sách."""
    catalog = load_catalog(args.catalog)
    cases = catalog.get("cases", [])
    seen_urls, seen_ids, seen_refs, out = set(), set(), set(), []
    removed_urls, removed_refs, renamed = 0, 0, 0
    for entry in cases:
        url = entry.get("url", "")
        if url in seen_urls:
            removed_urls += 1
            continue
        # Cùng một item (source_ref) = cùng một file → chỉ giữ một bản.
        ref = entry.get("source_ref")
        if ref and entry.get("source_api", "").startswith("archive") and ref in seen_refs:
            removed_refs += 1
            continue
        if ref:
            seen_refs.add(ref)
        seen_urls.add(url)
        eid = entry.get("id", "")
        if eid in seen_ids:
            digest = hashlib.md5(url.encode("utf-8")).hexdigest()[:6]
            entry = {**entry, "id": f"{eid}_{digest}"}
            renamed += 1
        seen_ids.add(entry["id"])
        out.append(entry)
    catalog["cases"] = out
    print(f"Bỏ {removed_urls} URL trùng, {removed_refs} item trùng, đổi id cho {renamed} mục (còn {len(out)})")
    if args.update_config:
        save_catalog(catalog, args.catalog)
        print(f"Đã ghi vào {args.catalog}")
    return 0


def main():
    # Cờ chung: khai báo ở parent để dùng được cả trước và sau lệnh con.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--catalog", default=CATALOG_PATH)
    common.add_argument("--concurrency", type=int, default=24)
    common.add_argument("--update-config", action="store_true", help="Ghi thay đổi vào file catalog")
    common.add_argument("--retire-after", type=int, default=3)
    common.add_argument("--add", type=int, default=60)
    common.add_argument("--allow-same-host", action="store_true")
    common.add_argument("--replace-dead", action="store_true", help="Thay URL cho nguồn đã chết")
    common.add_argument("--replace", type=int, default=40, help="Số nguồn chết tối đa được thay")
    common.add_argument("--prune", action="store_true", help="Xoá hẳn nguồn không dùng được khỏi danh sách")

    parser = argparse.ArgumentParser(
        description="Quản lý danh sách nguồn media kiểm thử", parents=[common]
    )
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("probe", parents=[common], help="Kiểm tra sống/chết mọi URL")
    sub.add_parser("refresh", parents=[common], help="Làm mới URL cho nguồn có source_api")
    sub.add_parser("repair", parents=[common], help="refresh + retire nguồn chết nhiều lần")
    one = sub.add_parser("refresh-one", parents=[common], help="In URL mới cho một nguồn (dùng cho tự chữa)")
    one.add_argument("id")
    disc = sub.add_parser("discover", parents=[common], help="Sinh nguồn mới từ API công khai")
    sub.add_parser("sync-kinds", parents=[common], help="Đồng bộ kind/expect_streams theo file thật")
    sub.add_parser("dedupe", parents=[common], help="Bỏ URL trùng / id trùng")
    cap = sub.add_parser("cap-families", parents=[common], help="Giới hạn số nguồn theo họ host")
    cap.add_argument("--default-max", type=int, default=60)
    cap.add_argument("--family-max", action="append", default=[], help="gioi_han=family,so")
    sfr = sub.add_parser("sync-from-results", parents=[common], help="Đồng bộ theo kết quả harness (JSON)")
    sfr.add_argument("--results", required=True)

    args = parser.parse_args()
    if args.cmd == "probe":
        return cmd_probe(args)
    if args.cmd == "refresh":
        return cmd_refresh(args)
    if args.cmd == "repair":
        return cmd_repair(args)
    if args.cmd == "refresh-one":
        return cmd_refresh_one(args)
    if args.cmd == "discover":
        return cmd_discover(args)
    if args.cmd == "cap-families":
        args.max_per_family = {}
        for item in args.family_max:
            if "=" in item:
                fam, _, count = item.partition("=")
                args.max_per_family[fam.strip()] = int(count)
        return cmd_cap_families(args)
    if args.cmd == "dedupe":
        return cmd_dedupe(args)
    if args.cmd == "sync-kinds":
        return cmd_sync_kinds(args)
    if args.cmd == "sync-from-results":
        return cmd_sync_from_results(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
