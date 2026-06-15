import json
import urllib.request
import urllib.error
import urllib.parse
from urllib.parse import parse_qs
from common.app_server import serve

# A User-Agent that public APIs accept
_UA = "Mozilla/5.0 (compatible; data-platform-discovery/1.0)"

def _get(url, timeout=10):
    req = urllib.request.Request(url, headers={"User-Agent": _UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())

# ─── source adapters ────────────────────────────────────────────────────────

def _fetch_apis_guru(limit=20):
    data = _get("https://api.apis.guru/v2/list.json")
    results = []
    for api_name, info in list(data.items())[:limit]:
        preferred = info.get("preferred", "")
        version_info = info.get("versions", {}).get(preferred, {})
        origins = version_info.get("info", {}).get("x-origin", [{}])
        base_url = origins[0].get("url", "") if origins else ""
        results.append({
            "name": api_name,
            "title": info.get("info", {}).get("title", api_name),
            "version": preferred,
            "baseUrl": base_url,
            "source": "apis-guru",
        })
    return results


def _fetch_public_apis(category=None, limit=20):
    url = "https://api.publicapis.org/entries"
    if category:
        url += f"?category={urllib.parse.quote(category)}"
    data = _get(url)
    return [
        {
            "name": e.get("API", ""),
            "title": e.get("Description", ""),
            "category": e.get("Category", ""),
            "baseUrl": e.get("Link", ""),
            "auth": e.get("Auth", "none"),
            "https": e.get("HTTPS", False),
            "source": "publicapis",
        }
        for e in data.get("entries", [])[:limit]
    ]


def _fetch_jsonplaceholder(limit=20):
    """Always-available free test APIs – no auth needed."""
    entries = [
        {"name": "jsonplaceholder-posts",  "title": "Blog posts",    "baseUrl": "https://jsonplaceholder.typicode.com/posts",   "category": "testing", "auth": "none", "https": True},
        {"name": "jsonplaceholder-users",  "title": "Users",         "baseUrl": "https://jsonplaceholder.typicode.com/users",   "category": "testing", "auth": "none", "https": True},
        {"name": "jsonplaceholder-todos",  "title": "Todos",         "baseUrl": "https://jsonplaceholder.typicode.com/todos",   "category": "testing", "auth": "none", "https": True},
        {"name": "jsonplaceholder-albums", "title": "Albums",        "baseUrl": "https://jsonplaceholder.typicode.com/albums",  "category": "testing", "auth": "none", "https": True},
        {"name": "jsonplaceholder-photos", "title": "Photos",        "baseUrl": "https://jsonplaceholder.typicode.com/photos",  "category": "testing", "auth": "none", "https": True},
        {"name": "openlibrary-search",     "title": "Open Library",  "baseUrl": "https://openlibrary.org/search.json",         "category": "books",   "auth": "none", "https": True},
        {"name": "catfact-ninja",          "title": "Cat Facts",     "baseUrl": "https://catfact.ninja/fact",                  "category": "animals", "auth": "none", "https": True},
        {"name": "dog-ceo",                "title": "Dog API",       "baseUrl": "https://dog.ceo/api/breeds/list/all",         "category": "animals", "auth": "none", "https": True},
        {"name": "restcountries",          "title": "REST Countries","baseUrl": "https://restcountries.com/v3.1/all",          "category": "geo",     "auth": "none", "https": True},
        {"name": "numbersapi",             "title": "Numbers API",   "baseUrl": "http://numbersapi.com/42",                    "category": "science", "auth": "none", "https": False},
    ]
    return [dict(e, source="jsonplaceholder") for e in entries[:limit]]


def _fetch_coingecko(limit=20):
    coins = _get("https://api.coingecko.com/api/v3/coins/list")
    return [
        {
            "name": f"coingecko-{c['id']}",
            "title": c.get("name", ""),
            "baseUrl": f"https://api.coingecko.com/api/v3/coins/{c['id']}",
            "category": "crypto",
            "auth": "none",
            "https": True,
            "source": "coingecko",
        }
        for c in coins[:limit]
    ]


_SOURCES = {
    "apis-guru":       lambda p: _fetch_apis_guru(int(p.get("limit", ["20"])[0])),
    "publicapis":      lambda p: _fetch_public_apis(p.get("category", [None])[0], int(p.get("limit", ["20"])[0])),
    "jsonplaceholder": lambda p: _fetch_jsonplaceholder(int(p.get("limit", ["20"])[0])),
    "coingecko":       lambda p: _fetch_coingecko(int(p.get("limit", ["20"])[0])),
}

# ─── handler ────────────────────────────────────────────────────────────────

def handle(method, parsed, payload, state):
    if method == "GET" and parsed.path == "/discover":
        params = parse_qs(parsed.query)
        source = params.get("source", ["jsonplaceholder"])[0]
        if source not in _SOURCES:
            return {"error": f"unknown source '{source}'. Available: {list(_SOURCES)}"}
        try:
            apis = _SOURCES[source](params)
            return {"source": source, "count": len(apis), "apis": apis, "status": "ok"}
        except Exception as exc:
            return {"source": source, "error": str(exc), "apis": [], "status": "error"}

    if method == "GET" and parsed.path == "/sources":
        return {"sources": list(_SOURCES.keys())}

    if method == "POST" and parsed.path == "/discover":
        items = payload.get("items", [])
        return {"source": "manual", "count": len(items), "apis": items, "status": "ok"}

    return None


if __name__ == "__main__":
    serve("api-discovery", 8080, handle)
