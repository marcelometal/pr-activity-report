#!/usr/bin/env python3
"""Gera relatorio-prs-<handle>.html a partir de report.template.html + data/<handle>.json.

Uso:  python3 scripts/generate.py <handle>

data/<handle>.json:
  { "handle": "...", "name": "...", "generated": "DD mon AAAA",
    "org": "...", "window": "...",            # org e janela (rótulos de exibição)
    "data": [ {n,t,r,s,d,u,p?}, ... ],       # PRs de autoria
    "reviews": [ {n,t,r,s,d,u,a,k,p?}, ... ], # participações
    "themes": [ {title, meta, text}, ... ] }  # opcional (seção editorial)
"""
import json, sys, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MO = {"01": "jan", "02": "fev", "03": "mar", "04": "abr", "05": "mai", "06": "jun",
      "07": "jul", "08": "ago", "09": "set", "10": "out", "11": "nov", "12": "dez"}


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;")


def fmt_date(d):
    y, m, dd = d.split("-")
    return f"{int(dd)} {MO[m]} {y}"


def jdump(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")


def main(handle):
    meta = json.load(open(os.path.join(ROOT, "data", f"{handle}.json")))
    name, gen = meta["name"], meta.get("generated", "")
    data, reviews = meta["data"], meta["reviews"]

    total = len(data)
    merged = sum(1 for p in data if p["s"] == "merged")
    open_ = sum(1 for p in data if p["s"] == "open")
    repos = len({p["r"] for p in data})
    pct = merged * 100 // total if total else 0
    rtotal = len(reviews)
    rreview = sum(1 for p in reviews if p["k"] == "review")
    rcomment = sum(1 for p in reviews if p["k"] == "comment")
    rauthors = len({p["a"] for p in reviews})

    ds = sorted(p["d"] for p in data)
    start, end = ds[0], ds[-1]
    months = sorted({p["d"][:7] for p in data})
    base_year = max(m.split("-")[0] for m in months)
    moname = {m: MO[m.split("-")[1]] + (f"'{m[2:4]}" if m.split("-")[0] != base_year else "")
              for m in months}

    data_keys = ["n", "t", "r", "s", "d", "u"]
    rev_keys = ["n", "t", "r", "s", "d", "u", "a", "k"]
    data_out = [{**{k: p[k] for k in data_keys}, **({"p": p["p"]} if p.get("p") else {})} for p in data]
    rev_out = [{**{k: p[k] for k in rev_keys}, **({"p": p["p"]} if p.get("p") else {})} for p in reviews]

    themes_html = ""
    if meta.get("themes"):
        cards = "\n".join(
            f'      <div class="theme">\n'
            f'        <h3>{esc(t["title"])}</h3>\n'
            f'        <p class="meta">{esc(t.get("meta", ""))}</p>\n'
            f'        <p>{esc(t.get("text", ""))}</p>\n'
            f'      </div>' for t in meta["themes"])
        themes_html = ('\n  <section>\n    <h2>Principais frentes de trabalho</h2>\n'
                       f'    <div class="themes">\n{cards}\n    </div>\n  </section>\n')

    org = meta.get("org", "")
    window = meta.get("window") or "janela completa"
    mono_note = ("· monorepos detalhados por subprojeto"
                 if any(p.get("p") for p in data) or any(p.get("p") for p in reviews)
                 else "")

    lede = meta.get("lede") or (
        f"{total} pull requests em {repos} repositórios distintos no período, "
        f"{merged} deles merged ({pct}%). Mais participação em {rtotal} PRs de "
        f"outras pessoas, entre reviews e comentários.")

    css = open(os.path.join(ROOT, "report.css")).read().rstrip("\n")

    repl = {
        "CSS": css,
        "NAME": esc(name), "HANDLE": handle, "LEDE": lede,
        "ORG": esc(org), "WINDOW": esc(window), "MONONOTE": mono_note,
        "START": fmt_date(start), "END": fmt_date(end), "GENERATED": gen,
        "TOTAL": total, "MERGED": merged, "PCT": pct, "OPEN": open_, "REPOS": repos,
        "RTOTAL": rtotal, "RREVIEW": rreview, "RCOMMENT": rcomment, "RAUTHORS": rauthors,
        "THEMES": themes_html,
        "DATA_JSON": jdump(data_out), "REVIEWS_JSON": jdump(rev_out),
        "MONTHS_JSON": jdump(months), "MONAME_JSON": jdump(moname),
    }
    tpl = open(os.path.join(ROOT, "report.template.html")).read()
    for k, v in repl.items():
        tpl = tpl.replace("{{" + k + "}}", str(v))

    left = re.findall(r"{{[A-Z_]+}}", tpl)
    if left:
        sys.exit(f"ERRO: placeholders não preenchidos: {set(left)}")

    out_dir = os.path.join(ROOT, "reports")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"relatorio-prs-{handle}.html")
    open(out, "w").write(tpl)
    print(f"OK  {out}  ({len(tpl)} bytes)")
    print(f"    DATA {total} (merged {merged}/{pct}%, open {open_}, repos {repos}) | "
          f"REVIEWS {rtotal} (review {rreview}, comment {rcomment}, autores {rauthors})")
    print(f"    período {fmt_date(start)} → {fmt_date(end)} | {len(months)} meses")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("uso: python3 scripts/generate.py <handle>")
    main(sys.argv[1])
