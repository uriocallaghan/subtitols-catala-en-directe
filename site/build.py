#!/usr/bin/env python3
"""Builds duna.uriocallaghan.com into site/public from the fragments in site/pages.

Each fragment is site/pages/<lang>/<page>.html: a `title:` line, a `description:` line,
a blank line, then the page's <main> content. Pages link to each other with {{privacy}},
{{terms}}, {{legal}}, {{support}} and {{home}}, which become the path in the page's own
language. Run: python3 site/build.py  (then: cd site && netlify deploy --prod)
"""
import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parent
PAGES = ROOT / "pages"
PUBLIC = ROOT / "public"

LANGUAGES = {
    "ca": {"prefix": "", "name": "Català"},
    "es": {"prefix": "/es", "name": "Español"},
    "en": {"prefix": "/en", "name": "English"},
}
# The published file for each page in each language (Netlify serves /x from x.html).
SLUGS = {
    "home":    {"ca": "index", "es": "index",      "en": "index"},
    "privacy": {"ca": "privacitat", "es": "privacidad", "en": "privacy"},
    "terms":   {"ca": "condicions", "es": "condiciones", "en": "terms"},
    "legal":   {"ca": "avis-legal", "es": "aviso-legal", "en": "legal"},
    "support": {"ca": "suport", "es": "soporte", "en": "support"},
}
LABELS = {
    "ca": {"privacy": "Privacitat", "terms": "Condicions d'ús", "legal": "Avís legal", "support": "Suport"},
    "es": {"privacy": "Privacidad", "terms": "Condiciones de uso", "legal": "Aviso legal", "support": "Soporte"},
    "en": {"privacy": "Privacy Policy", "terms": "Terms of Use", "legal": "Legal Notice", "support": "Support"},
}


def path(page, lang):
    slug = SLUGS[page][lang]
    prefix = LANGUAGES[lang]["prefix"]
    return f"{prefix}/" if slug == "index" else f"{prefix}/{slug}"


def render(page, lang, title, description, body):
    for key in SLUGS:
        body = body.replace("{{" + key + "}}", path(key, lang))
    labels = LABELS[lang]
    switcher = "".join(
        f'<span lang="{code}">{code.upper()}</span>' if code == lang
        else f'<a href="{path(page, code)}" lang="{code}" hreflang="{code}">{code.upper()}</a>'
        for code in LANGUAGES
    )
    alternates = "\n".join(
        f'<link rel="alternate" hreflang="{code}" href="https://duna.uriocallaghan.com{path(page, code)}">'
        for code in LANGUAGES
    )
    name = '<span class="name">duna</span>' if page == "home" else f'<a class="name" href="{path("home", lang)}">duna</a>'
    footer_links = "\n    ".join(f'<a href="{path(key, lang)}">{labels[key]}</a>' for key in ("privacy", "terms", "legal", "support"))
    full_title = "duna" if page == "home" else f"{title} · duna"
    return f"""<!DOCTYPE html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{full_title}</title>
<meta name="description" content="{description}">
{alternates}
<link rel="icon" href="/favicon-64.png" type="image/png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<div class="page">

<header class="masthead">
    <img src="/mark.png" alt="">
    {name}
    <nav class="languages" aria-label="Language">{switcher}</nav>
</header>

{body.strip()}

<footer>
    <span>duna · Oriol O'Callaghan</span>
    {footer_links}
</footer>

</div>
</body>
</html>
"""


def main():
    if PUBLIC.exists():
        shutil.rmtree(PUBLIC)
    PUBLIC.mkdir()
    for asset in (ROOT / "src").iterdir():
        shutil.copy(asset, PUBLIC / asset.name)
    for lang in LANGUAGES:
        for page in SLUGS:
            source = (PAGES / lang / f"{page}.html").read_text(encoding="utf-8")
            header, body = source.split("\n\n", 1)
            meta = dict(line.split(": ", 1) for line in header.splitlines())
            html = render(page, lang, meta["title"], meta["description"], body)
            out = PUBLIC / (path(page, lang).lstrip("/") or "")
            target = (out / "index.html") if path(page, lang).endswith("/") else out.with_suffix(".html")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(html, encoding="utf-8")
    print("\n".join(sorted(str(p.relative_to(PUBLIC)) for p in PUBLIC.rglob("*") if p.is_file())))


if __name__ == "__main__":
    main()
