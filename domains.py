"""Leitet aus den freien Listen eine Domainliste für den Schutz in allen Apps (DNS auf dem Gerät) ab.

DNS kennt nur Domains, keine Pfade und nicht, ob ein Abruf von Dritten kommt. Deshalb vorsichtig:
- nur Regeln der Form ||domain^ ohne Einschränkung auf bestimmte Seiten (domain=) oder Erstanbieter;
- Domains mit einer globalen Ausnahmeregel (auch nur für Pfade oder Subdomains) werden nie geblockt; Ausnahmen
  nur für einzelne Seiten (domain=) oder nur für Pop-ups zählen nicht, sonst fielen alle großen Werbedomains weg;
- eine feste Schutzliste großer Dienste wird nie geblockt (auch nicht deren Subdomains, wenn eine Regel die
  ganze Domain träfe).
"""
import re

RULE = re.compile(r"^\|\|([a-z0-9][a-z0-9.-]*\.[a-z][a-z0-9-]+)\^(?:\$(.*))?$")
EXCEPTION = re.compile(r"^@@\|\|([a-z0-9][a-z0-9.-]*\.[a-z][a-z0-9-]+)[^$]*(?:\$(.*))?$")
# Ausnahmen, die für DNS keine Rolle spielen: nur für einzelne Seiten (domain=) oder nur Pop-ups/Ausblenden
IGNORED_EXCEPTION_OPTIONS = {"popup", "elemhide", "ehide", "generichide", "ghide", "specifichide", "shide",
                             "redirect-rule", "genericblock"}
HOSTS = re.compile(r"^(?:0\.0\.0\.0|127\.0\.0\.1)\s+([a-z0-9][a-z0-9.-]*\.[a-z][a-z0-9-]+)$")
BARE = re.compile(r"^([a-z0-9][a-z0-9.-]*\.[a-z][a-z0-9-]+)$")
ALLOWED_OPTIONS = {"third-party", "3p", "script", "image", "subdocument", "xmlhttprequest", "ping", "other",
                   "stylesheet", "font", "media", "all", "important", "popup", "websocket", "object"}

# Dienste, die Menschen und Apps direkt nutzen. Lieber eine Werbedomain durchlassen als iCloud kaputtmachen.
PROTECTED = """
apple.com icloud.com icloud-content.com mzstatic.com apple-cloudkit.com cdn-apple.com apple-dns.net aaplimg.com
google.com google.de googleapis.com gstatic.com googleusercontent.com googlevideo.com youtube.com ytimg.com ggpht.com
gmail.com android.com recaptcha.net
microsoft.com live.com office.com office.net outlook.com windows.net windows.com msftconnecttest.com skype.com
azureedge.net bing.com
facebook.com fbcdn.net instagram.com cdninstagram.com whatsapp.com whatsapp.net messenger.com
amazon.com amazon.de amazonaws.com media-amazon.com ssl-images-amazon.com cloudfront.net
akamai.net akamaihd.net akamaized.net edgekey.net edgesuite.net fastly.net cloudflare.com cloudflare.net
paypal.com paypalobjects.com stripe.com klarna.com sparkasse.de dkb.de ing.de comdirect.de n26.com
github.com githubusercontent.com wikipedia.org wikimedia.org mozilla.org mozilla.net
netflix.com nflxvideo.net spotify.com scdn.co zoom.us slack.com dropbox.com telegram.org signal.org
twitter.com x.com twimg.com linkedin.com licdn.com pinterest.com reddit.com redditmedia.com tiktok.com
""".split()


def parse(lines):
    blocked, excepted = set(), set()
    for raw in lines:
        line = raw.strip().lower()
        if not line or line.startswith(("!", "#", "[")):
            continue
        m = EXCEPTION.match(line)
        if m:
            options = set(filter(None, (m.group(2) or "").split(",")))
            site_specific = any(o.startswith(("domain=", "from=")) for o in options)
            if not site_specific and not (options and options <= IGNORED_EXCEPTION_OPTIONS):
                excepted.add(m.group(1))
            continue
        if line.startswith("@@"):
            continue
        m = RULE.match(line)
        if m:
            options = set(filter(None, (m.group(2) or "").split(",")))
            if options <= ALLOWED_OPTIONS:
                blocked.add(m.group(1))
            continue
        m = HOSTS.match(line) or BARE.match(line)
        if m:
            blocked.add(m.group(1))
    return blocked, excepted


def parents(domain):
    parts = domain.split(".")
    return {".".join(parts[i:]) for i in range(len(parts) - 1)}


def build(lines, extra=()):
    blocked, excepted = parse(lines)
    keep_free = set(PROTECTED) | excepted
    # Eine Domain fällt weg, wenn sie selbst oder eine übergeordnete Domain geschützt ist,
    # oder wenn sie über einer geschützten bzw. ausgenommenen Domain liegt (würde diese mitblocken).
    protected_parents = set()
    for d in keep_free:
        protected_parents |= parents(d)
    result = {d for d in blocked if d not in protected_parents and not (parents(d) & set(PROTECTED))}
    # Eigene, genau benannte Hosts: dürfen unter geschützten Domains liegen, aber nie selbst geschützt sein
    result |= {d for d in extra if d not in PROTECTED}
    # Redundante Subdomains entfernen (blockt ohnehin die übergeordnete Domain)
    return sorted(d for d in result if not (parents(d) - {d}) & result)


MUST_BLOCK = ["ad.doubleclick.net", "securepubads.g.doubleclick.net", "pagead2.googlesyndication.com",
              "www.google-analytics.com", "www.googletagmanager.com", "cdn.taboola.com", "widgets.outbrain.com",
              "static.criteo.net", "ib.adnxs.com", "c.amazon-adsystem.com", "sb.scorecardresearch.com", "static.hotjar.com"]
MUST_NOT_BLOCK = ["apple.com", "www.apple.com", "icloud.com", "p01-caldav.icloud.com", "google.com", "youtube.com",
                  "i.ytimg.com", "rr1---sn-4g5e6nzz.googlevideo.com", "whatsapp.net", "graph.facebook.com",
                  "www.paypal.com", "github.com", "api.github.com", "login.microsoftonline.com", "en.wikipedia.org",
                  "www.amazon.de", "d1.cloudfront.net", "www.spiegel.de", "www.tagesschau.de"]


def is_blocked(domain, domains):
    return bool(({domain} | parents(domain)) & domains)
