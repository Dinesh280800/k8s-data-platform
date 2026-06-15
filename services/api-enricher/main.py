from common.app_server import serve

# keyword-based category tags so the enricher works without a DB
_CATEGORY_TAGS = {
    "weather": ["environment", "iot"],
    "finance": ["fintech", "payments"],
    "crypto": ["fintech", "blockchain"],
    "maps": ["geo", "location"],
    "social": ["community", "user-generated"],
    "sports": ["entertainment", "real-time"],
    "news": ["media", "content"],
    "food": ["lifestyle", "commerce"],
    "music": ["entertainment", "media"],
    "book": ["education", "content"],
    "health": ["health", "wellness"],
    "government": ["open-data", "compliance"],
    "science": ["research", "education"],
}

_AUTH_LABELS = {
    "": "none",
    "none": "none",
    "apikey": "api-key",
    "oauth": "oauth2",
    "x-mashape-key": "api-key",
    "no": "none",
    "yes": "token",
}


def _infer_tags(item):
    combined = " ".join([
        item.get("name", ""),
        item.get("title", ""),
        item.get("category", ""),
    ]).lower()
    tags = ["public", "rest"]
    for keyword, extra in _CATEGORY_TAGS.items():
        if keyword in combined:
            tags.extend(extra)
    return list(dict.fromkeys(tags))  # deduplicate, preserve order


def _normalise_auth(raw):
    return _AUTH_LABELS.get(str(raw).lower(), "token")


def _sla_tier(latency_ms):
    if latency_ms == 0:
        return "unknown"
    if latency_ms < 200:
        return "fast"
    if latency_ms < 800:
        return "medium"
    return "slow"


def handle(method, parsed, payload, state):
    if parsed.path == "/enrich" and method == "POST":
        tags = _infer_tags(payload)
        return {
            "apiId": payload.get("apiId", payload.get("name", "")),
            "name": payload.get("name", ""),
            "category": payload.get("category", "general"),
            "auth": _normalise_auth(payload.get("auth", "none")),
            "https": payload.get("https", True),
            "tags": tags,
            "slaTier": _sla_tier(payload.get("latencyMs", 0)),
            "enriched": True,
        }

    if parsed.path == "/enrich/batch" and method == "POST":
        items = payload.get("items", [])
        enriched = []
        for item in items:
            tags = _infer_tags(item)
            enriched.append({
                "apiId": item.get("name", ""),
                "name": item.get("name", ""),
                "category": item.get("category", "general"),
                "auth": _normalise_auth(item.get("auth", "none")),
                "https": item.get("https", True),
                "tags": tags,
                "slaTier": _sla_tier(item.get("latencyMs", 0)),
                "baseUrl": item.get("baseUrl", item.get("url", "")),
                "enriched": True,
            })
        return {"enriched": len(enriched), "items": enriched}

    return None


if __name__ == "__main__":
    serve("api-enricher", 8080, handle)
